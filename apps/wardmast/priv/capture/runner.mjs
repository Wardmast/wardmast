#!/usr/bin/env node
//
// arb-capture: take ONE screenshot of ONE route of a running app (bd-485ts3, design N1).
//
//   node runner.mjs <spec.json>
//
// `Wardmast.Screenshots.Capture.Shooter.Cdp` writes the spec and reads the answer: the LAST line
// of stdout is one JSON object,
//
//   {"ok":true,"blocked":[...]}                              the image is at spec.out_file
//   {"ok":false,"kind":"http_status","status":404}           the route answered >= 400
//   {"ok":false,"kind":"shot","reason":"..."}                anything else (login, a step, ...)
//
// and the exit status is 0 whenever an answer was printed. This runs headless Chromium
// (`spec.chrome`) over CDP through playwright-core, one fresh browser context per shot, so a shot
// never sees another shot's cookies. It is deliberately a dumb executor of the declarative spec:
// no worker-supplied code runs here, and the only network it may reach is the loopback app.
//
// A login is a form login: fill, submit, then PROVE it worked against `login.success`
// (`path_not` / `url_not_contains`). A sign-in page is never shot as a result page: if the
// login does not succeed, or the shot's own navigation lands back on the sign-in page, the shot
// fails with the reason.

import { mkdtempSync, readFileSync, rmSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

const MAX_FULL_PAGE_PX = 8000
const STEP_TIMEOUT_MS = 5000
const MAX_WAIT_MS = 10000
const MAX_PAUSE_MS = 2000
const LOOPBACK = new Set(["127.0.0.1", "localhost", "[::1]", "::1"])

class ShotError extends Error {
  constructor(kind, message, extra = {}) {
    super(message)
    this.kind = kind
    this.extra = extra
  }
}

const fail = (message) => new ShotError("shot", message)

function emit(result) {
  process.stdout.write("\n" + JSON.stringify(result) + "\n")
}

const firstLine = (err) =>
  String((err && err.message) || err)
    .split("\n")[0]
    .slice(0, 300)

// ── success detection ────────────────────────────────────────────────────

// `success` is `{path_not: "/login"}` and/or `{url_not_contains: "/login"}`; every given
// condition must hold. Returns `(url) => boolean`.
function successMatcher(success) {
  const conds = []
  if (success && typeof success.path_not === "string" && success.path_not !== "") {
    conds.push((u) => new URL(u).pathname !== success.path_not)
  }
  if (success && typeof success.url_not_contains === "string" && success.url_not_contains !== "") {
    conds.push((u) => !u.includes(success.url_not_contains))
  }
  if (conds.length === 0) throw fail("login.success has neither path_not nor url_not_contains")
  return (u) => conds.every((c) => c(u))
}

const describeSuccess = (success) =>
  Object.entries(success)
    .map(([k, v]) => `${k} ${JSON.stringify(v)}`)
    .join(", ")

const where = (url) => {
  try {
    return new URL(url).pathname
  } catch {
    return url
  }
}

// ── helpers ──────────────────────────────────────────────────────────────

function loopbackUrl(url) {
  try {
    const u = new URL(url)
    if (["data:", "blob:", "about:"].includes(u.protocol)) return true
    return ["http:", "https:", "ws:", "wss:"].includes(u.protocol) && LOOPBACK.has(u.hostname)
  } catch {
    return false
  }
}

function withQuery(base, path, query) {
  let url = base + path
  const q = new URLSearchParams(query || {}).toString()
  if (q !== "") url += (url.includes("?") ? "&" : "?") + q
  return url
}

const clamp = (v, lo, hi, dflt) => (Number.isFinite(v) ? Math.min(Math.max(v, lo), hi) : dflt)

const str = (v, what) => {
  if (typeof v !== "string" || v === "") throw fail(`${what} must be a non-empty string`)
  return v
}

async function settle(page, ms = 3000) {
  // Best effort: an app that never goes network-idle (long polls) is shot as it stands.
  await page.waitForLoadState("networkidle", { timeout: ms }).catch(() => {})
  await page.evaluate(() => document.fonts && document.fonts.ready).catch(() => {})
}

// ── login ────────────────────────────────────────────────────────────────

async function doLogin(page, spec, timeoutMs) {
  const login = spec.login
  if (login.kind !== "form") {
    throw fail(`login.kind ${JSON.stringify(login.kind)} is not supported by the CDP shooter`)
  }
  const ok = successMatcher(login.success)
  const loginUrl = spec.base_url + login.path

  const resp = await page.goto(loginUrl, { waitUntil: "load", timeout: timeoutMs })
  if (resp && resp.status() >= 400) {
    throw fail(`login page GET ${login.path} answered ${resp.status()}`)
  }
  // A success condition the sign-in page already satisfies cannot tell a failed login from a
  // good one. Refuse rather than risk shooting the sign-in page as the "after".
  if (ok(page.url())) {
    throw fail(
      `login.success (${describeSuccess(login.success)}) is already true on the sign-in page ` +
        `${where(page.url())}, so it cannot detect a failed login`
    )
  }

  const step = clamp(login.timeout_ms, 1000, 30000, 10000)
  const fillField = async (selector, value, what) => {
    try {
      await page.locator(selector).fill(value, { timeout: STEP_TIMEOUT_MS })
    } catch (err) {
      throw fail(`login: the ${what} field ${JSON.stringify(selector)}: ${firstLine(err)}`)
    }
  }
  await fillField(login.username_selector, login.username, "username")
  await fillField(login.password_selector, login.password, "password")

  try {
    await page.locator(login.submit_selector).click({ timeout: STEP_TIMEOUT_MS })
  } catch (err) {
    throw fail(`login: the submit button ${JSON.stringify(login.submit_selector)}: ${firstLine(err)}`)
  }

  try {
    await page.waitForURL((u) => ok(u.toString()), { timeout: step, waitUntil: "commit" })
  } catch {
    throw fail(
      `login as ${JSON.stringify(login.persona)} did not succeed: still on ${where(page.url())} ` +
        `${step} ms after submitting (login.success: ${describeSuccess(login.success)})`
    )
  }
  // The redirect chain must come to rest somewhere that still counts as logged in.
  await page.waitForLoadState("load", { timeout: step }).catch(() => {})
  if (!ok(page.url())) {
    throw fail(
      `login as ${JSON.stringify(login.persona)} did not succeed: ended on ${where(page.url())} ` +
        `(login.success: ${describeSuccess(login.success)})`
    )
  }
}

// ── steps ────────────────────────────────────────────────────────────────

async function runStep(page, spec, step, theme) {
  const action = step.action
  const loc = () => page.locator(str(step.selector, "selector"))
  const opts = { timeout: STEP_TIMEOUT_MS }
  switch (action) {
    case "click":
      return loc().click(opts)
    case "hover":
      return loc().hover(opts)
    case "fill":
      return loc().fill(String(step.value ?? ""), opts)
    case "select":
      return loc().selectOption(String(step.value ?? ""), opts)
    case "check":
      return loc().check(opts)
    case "uncheck":
      return loc().uncheck(opts)
    case "press":
      return step.selector
        ? loc().press(str(step.key, "key"), opts)
        : page.keyboard.press(str(step.key, "key"))
    case "scroll_to":
      return loc().scrollIntoViewIfNeeded(opts)
    case "goto": {
      const resp = await page.goto(withQuery(spec.base_url, str(step.path, "path"), theme.query), {
        waitUntil: "load",
        timeout: spec.timeout_ms
      })
      if (resp && resp.status() >= 400) throw fail(`GET ${step.path} answered ${resp.status()}`)
      return undefined
    }
    case "wait_for":
      return waitFor(page, step)
    case "wait":
      return page.waitForTimeout(clamp(step.ms, 0, MAX_PAUSE_MS, 0))
    default:
      throw fail(`unknown step action ${JSON.stringify(action)}`)
  }
}

async function waitFor(page, w) {
  const state = w.state === "hidden" ? "hidden" : "visible"
  const timeout = clamp(w.timeout_ms, 100, MAX_WAIT_MS, STEP_TIMEOUT_MS)
  const target =
    typeof w.text === "string" && w.text !== "" && !w.selector
      ? page.getByText(w.text).first()
      : page.locator(str(w.selector, "selector"))
  await target.waitFor({ state, timeout })
}

// ── the shot ─────────────────────────────────────────────────────────────

// Chromium puts a unix socket under $TMPDIR and aborts when the path exceeds ~100 bytes, which a
// deep per-run scratch directory does. Give the browser (and playwright-core) a short one.
function shortScratch() {
  const base = tmpdir().length <= 40 ? tmpdir() : "/tmp"
  const dir = mkdtempSync(join(base, "arbcap-"))
  process.env.TMPDIR = dir
  return dir
}

async function shoot(spec) {
  const base = new URL(spec.base_url)
  if (!LOOPBACK.has(base.hostname)) {
    throw fail(`base_url host ${base.hostname} is not loopback`)
  }
  let playwright
  try {
    playwright = await import("playwright-core")
  } catch (err) {
    throw fail(`playwright-core is not installed next to the runner (${firstLine(err)})`)
  }

  const viewport = spec.viewport
  const theme = spec.theme || {}
  const shot = spec.shot || {}
  const blocked = []

  const scratch = shortScratch()
  const browser = await playwright.chromium.launch({
    executablePath: spec.chrome,
    headless: true,
    args: [
      "--no-sandbox",
      "--disable-gpu",
      "--disable-dev-shm-usage",
      "--hide-scrollbars",
      "--lang=en-US",
      // No name resolution beyond loopback: the browser cannot even look up an outside host.
      "--host-resolver-rules=MAP * ~NOTFOUND, EXCLUDE 127.0.0.1, EXCLUDE localhost"
    ],
    env: { ...process.env, TZ: "UTC" }
  })

  try {
    const context = await browser.newContext({
      viewport: { width: viewport.width, height: viewport.height },
      deviceScaleFactor: viewport.device_scale_factor || 1,
      locale: "en-US",
      timezoneId: "UTC",
      colorScheme: theme.color_scheme === "dark" ? "dark" : "light",
      reducedMotion: "reduce",
      serviceWorkers: "block",
      acceptDownloads: false
    })
    // Belt and braces with the resolver rules: refuse anything that is not loopback.
    await context.route("**/*", (route) => {
      const url = route.request().url()
      if (loopbackUrl(url)) return route.continue()
      blocked.push(url.slice(0, 200))
      return route.abort("blockedbyclient")
    })

    const storage = Object.entries(theme.local_storage || {})
    if (storage.length > 0) {
      await context.addInitScript(
        ({ entries, origin }) => {
          if (location.origin !== origin) return
          for (const [k, v] of entries) localStorage.setItem(k, String(v))
        },
        { entries: storage, origin: base.origin }
      )
    }
    await context.clock.setFixedTime(new Date(spec.fixed_time || "2026-01-01T12:00:00Z"))

    const page = await context.newPage()
    page.setDefaultNavigationTimeout(spec.timeout_ms)

    if (spec.login) await doLogin(page, spec, spec.timeout_ms)

    const resp = await page.goto(withQuery(spec.base_url, spec.path, theme.query), {
      waitUntil: "load",
      timeout: spec.timeout_ms
    })
    if (resp && resp.status() >= 400) {
      throw new ShotError("http_status", `GET ${spec.path} answered ${resp.status()}`, {
        status: resp.status()
      })
    }
    assertStillLoggedIn(page, spec)

    for (const [i, step] of (shot.steps || []).entries()) {
      try {
        await runStep(page, spec, step, theme)
      } catch (err) {
        const what = step.selector ? ` ${JSON.stringify(step.selector)}` : ""
        throw fail(`step ${i + 1} (${step.action}${what}) failed: ${firstLine(err)}`)
      }
    }
    assertStillLoggedIn(page, spec)

    if (shot.wait_for) {
      try {
        await waitFor(page, shot.wait_for)
      } catch (err) {
        throw fail(`wait_for ${JSON.stringify(shot.wait_for.selector)} failed: ${firstLine(err)}`)
      }
    }

    await settle(page)
    for (const selector of shot.hide || []) {
      await page
        .locator(selector)
        .evaluateAll((els) => els.forEach((e) => e.style.setProperty("visibility", "hidden", "important")))
    }

    await capture(page, spec, shot, viewport)
    return { ok: true, blocked }
  } finally {
    await browser.close().catch(() => {})
    rmSync(scratch, { recursive: true, force: true })
  }
}

// The route (or a step) bounced us back to the sign-in page: the session did not hold. Only
// meaningful when the route itself is not one the success condition would reject.
function assertStillLoggedIn(page, spec) {
  if (!spec.login) return
  const ok = successMatcher(spec.login.success)
  const requested = spec.base_url + spec.path
  if (ok(requested) && !ok(page.url())) {
    throw fail(
      `redirected to ${where(page.url())} after logging in (the login did not hold, or the ` +
        `persona may not open ${spec.path})`
    )
  }
}

async function capture(page, spec, shot, viewport) {
  const common = { path: spec.out_file, type: "png", animations: "disabled", caret: "hide" }
  const timeout = { timeout: spec.timeout_ms }
  try {
    if (shot.target) {
      await page.locator(str(shot.target.selector, "target.selector")).screenshot({ ...common, ...timeout })
    } else if (shot.full_page) {
      const height = await page.evaluate(() =>
        Math.max(document.documentElement.scrollHeight, (document.body || {}).scrollHeight || 0)
      )
      const clip =
        height > MAX_FULL_PAGE_PX
          ? { clip: { x: 0, y: 0, width: viewport.width, height: MAX_FULL_PAGE_PX } }
          : {}
      await page.screenshot({ ...common, ...timeout, fullPage: true, ...clip })
    } else {
      await page.screenshot({ ...common, ...timeout })
    }
  } catch (err) {
    throw fail(`taking the screenshot failed: ${firstLine(err)}`)
  }
}

// ── main ─────────────────────────────────────────────────────────────────

async function main() {
  let spec
  try {
    spec = JSON.parse(readFileSync(process.argv[2], "utf8"))
  } catch (err) {
    emit({ ok: false, kind: "shot", reason: `cannot read the spec: ${firstLine(err)}` })
    return 0
  }

  // A hard stop, so a hung page can never outlive the shot's budget.
  const guard = setTimeout(() => {
    emit({ ok: false, kind: "shot", reason: `timed out after ${spec.timeout_ms * 2} ms` })
    process.exit(1)
  }, spec.timeout_ms * 2)

  try {
    emit(await shoot(spec))
  } catch (err) {
    if (err instanceof ShotError) {
      emit({ ok: false, kind: err.kind, reason: err.message, ...err.extra })
    } else {
      emit({ ok: false, kind: "shot", reason: firstLine(err) })
    }
  }
  clearTimeout(guard)
  return 0
}

process.exit(await main())
