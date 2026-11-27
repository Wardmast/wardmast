#!/usr/bin/env node
//
// arb-capture: take ONE screenshot of ONE route of a running app (bd-485ts3, design N1).
//
//   node runner.mjs <spec.json>
//
// `Wardmast.Screenshots.Capture.Shooter.Cdp` writes the spec and reads the answer: the LAST line
// of stdout is one JSON object,
//
//   {"ok":true,"blocked":[...]}                              the image is at spec.out_file and the
//                                                            page's text (JSON) at spec.text_file
//   {"ok":false,"kind":"http_status","status":404}           the route answered >= 400
//   {"ok":false,"kind":"shot","reason":"..."}                anything else (login, a step, ...)
//   {"ok":false,"kind":"redirected","requested":"/a","final":"/b"}
//                                                            the route landed on another path (paths only)
//   {"ok":false,"kind":"fixture_marker","problem":"status|redirected|missing|failed"}
//                                                            the fixture marker was not shown in the
//                                                            logged-in session; nothing was shot
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

import { mkdtempSync, readFileSync, rmSync, unlinkSync, writeFileSync } from "node:fs"
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
    const trim = (p) => (p.length > 1 ? p.replace(/\/+$/, "") : p)
    conds.push((u) => trim(new URL(u).pathname) !== trim(success.path_not))
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

// The visible flash/alert text on the (PHI-free) sign-in page, for a failed login's reason: first
// line only, capped at 200 chars. "" when there is none.
async function visibleAlert(page) {
  try {
    const text = await page.evaluate(() => {
      const sel = '[role="alert"], .alert, [id^="flash"], [class*="flash"], [data-flash]'
      for (const el of document.querySelectorAll(sel)) {
        const r = el.getBoundingClientRect()
        const t = (el.innerText || "").trim()
        if (r.width > 0 && r.height > 0 && t !== "") return t
      }
      return ""
    })
    const line = String(text).split(/\r?\n/)[0].trim().slice(0, 200)
    return line === "" ? "" : `; the page says ${JSON.stringify(line)}`
  } catch {
    return ""
  }
}

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

  // A LiveView sign-in form is reset when its socket connects, so a fill made before that is
  // lost and a click before it can be swallowed. Wait for the configured ready_selector, or,
  // when the page is a LiveView, for its main view to be connected.
  const configured = typeof login.ready_selector === "string" && login.ready_selector !== ""
  const readySelector = configured
    ? login.ready_selector
    : (await page.$("[data-phx-main]")) !== null
      ? "[data-phx-main].phx-connected"
      : null
  if (readySelector !== null) {
    try {
      await page.waitForSelector(readySelector, { state: "attached", timeout: step })
    } catch {
      throw fail(
        `login: the page never became ready within ${step} ms: ` +
          `${configured ? "login.ready_selector" : "LiveView socket"} ${JSON.stringify(readySelector)} ` +
          `did not appear on ${where(page.url())}`
      )
    }
  }

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
    await page.waitForLoadState("load", { timeout: 2000 }).catch(() => {})
    throw fail(
      `login as ${JSON.stringify(login.persona)} did not succeed: still on ${where(page.url())} ` +
        `${step} ms after submitting (login.success: ${describeSuccess(login.success)})` +
        (await visibleAlert(page))
    )
  }
  // The redirect chain must come to rest somewhere that still counts as logged in.
  await page.waitForLoadState("load", { timeout: step }).catch(() => {})
  if (!ok(page.url())) {
    throw fail(
      `login as ${JSON.stringify(login.persona)} did not succeed: ended on ${where(page.url())} ` +
        `(login.success: ${describeSuccess(login.success)})` +
        (await visibleAlert(page))
    )
  }

  // A persona that belongs to several tenants lands on a picker after sign-in. The configured
  // post-login path (already rendered by the caller) selects one, e.g. a tenant switch.
  if (typeof login.post_login_path === "string" && login.post_login_path !== "") {
    const target = spec.base_url + login.post_login_path
    let resp
    try {
      resp = await page.goto(target, { waitUntil: "load", timeout: timeoutMs })
    } catch (err) {
      throw fail(`login.post_login_path ${login.post_login_path}: ${firstLine(err)}`)
    }
    if (resp && resp.status() >= 400) {
      throw fail(`login.post_login_path ${login.post_login_path} answered ${resp.status()}`)
    }
  }
}

// ── fixture marker ───────────────────────────────────────────────────────

// bd-ckriya: `fixture_check.marker` checked in THIS logged-in session, after the login and its
// post-login path and before the shot's own navigation, so a marker path behind the login (an
// anonymous GET only ever bounces to sign-in) can be verified. Nothing is shot if it fails. The
// answer carries a problem CODE (`status` / `redirected` / `missing` / `failed`) and the status,
// never the page's content or the needle: the host words the reason from the configured path.
async function checkFixtureMarker(page, spec, timeoutMs) {
  const marker = spec.fixture_marker
  if (!marker) return
  const problem = (code, extra = {}) =>
    new ShotError("fixture_marker", `fixture marker ${marker.path}: ${code}`, {
      problem: code,
      ...extra
    })

  let resp
  try {
    resp = await page.goto(spec.base_url + marker.path, { waitUntil: "load", timeout: timeoutMs })
  } catch {
    throw problem("failed")
  }
  if (!resp || resp.status() !== 200) throw problem("status", { status: resp ? resp.status() : 0 })

  const trim = (p) => (p.length > 1 ? p.replace(/\/+$/, "") : p)
  const wanted = trim(new URL(spec.base_url + marker.path).pathname)
  if (trim(new URL(page.url()).pathname) !== wanted) throw problem("redirected")

  // A LiveView page renders its content once connected: give the text a moment to appear.
  try {
    await page.waitForFunction(
      (needle) =>
        ((document.body && document.body.innerText) || "").includes(needle) ||
        document.documentElement.outerHTML.includes(needle),
      marker.contains,
      { timeout: Math.min(timeoutMs, 5000) }
    )
  } catch {
    throw problem("missing")
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
    await checkFixtureMarker(page, spec, spec.timeout_ms)

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
    assertNotRedirected(page, spec)

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
    if ((shot.steps || []).length === 0) assertNotRedirected(page, spec)
    for (const selector of shot.hide || []) {
      await page
        .locator(selector)
        .evaluateAll((els) => els.forEach((e) => e.style.setProperty("visibility", "hidden", "important")))
    }

    try {
      await writeText(page, spec)
    } catch (err) {
      throw fail(`reading the page text failed: ${firstLine(err)}`)
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

// bd-92wtof: the route (after any login / post-login round trip) must still be the page the shot
// asked for. A different final path is reported as {requested, final} (paths only, never content)
// and nothing is shot, unless the shot sets `allow_redirect`. Trailing slashes and the query string
// do not count as a redirect.
function assertNotRedirected(page, spec) {
  if ((spec.shot || {}).allow_redirect === true) return
  const trim = (p) => (p.length > 1 ? p.replace(/\/+$/, "") : p)
  const requested = trim(new URL(spec.base_url + spec.path).pathname)
  const final = trim(new URL(page.url()).pathname)
  if (requested !== final) {
    throw new ShotError("redirected", `route ${requested} redirected to ${final}`, {
      requested,
      final
    })
  }
}

// bd-995svb (design §9.5): what the page shows, as data for the host's data-safety scan: the
// visible text (`innerText`), the `alt` / `title` / `placeholder` / `aria-label` attributes and the
// value of every form field except a password. It goes to a file, never to stdout or the answer,
// so what the page said is in no log; the host scans it and keeps only the rule that matched.
async function writeText(page, spec) {
  if (!spec.text_file) return
  const texts = await page.evaluate(() => {
    const out = [document.body ? document.body.innerText : ""]
    for (const el of document.querySelectorAll("[alt],[title],[placeholder],[aria-label]")) {
      for (const a of ["alt", "title", "placeholder", "aria-label"]) {
        const v = el.getAttribute(a)
        if (v) out.push(v)
      }
    }
    for (const el of document.querySelectorAll("input,textarea,select")) {
      if (el.type !== "password" && el.value) out.push(String(el.value))
    }
    return out
  })
  writeFileSync(spec.text_file, JSON.stringify(texts), { mode: 0o600 })
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
    // It can hold a fixture password and lives in the shot's directory, which the browser can
    // see: gone before the browser starts.
    try {
      unlinkSync(process.argv[2])
    } catch {
      // the caller removes it too
    }
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
