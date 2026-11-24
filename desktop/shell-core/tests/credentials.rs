//! PKG 9: first-run credentials. The OS keychain is a stub, per platform.

use arbiter_shell_core::credentials::{
    base64, classify_get, ensure, keychain_ref, prepare, prepare_with, ref_env, CmdOutput,
    CredentialError, Os, OsStore, SecretStore, StoreError, CLOAK_ACCOUNT, SECRET_KEY_BASE_ACCOUNT,
    SERVICE,
};
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};

#[derive(Default)]
struct Inner {
    items: HashMap<String, String>,
    sets: Vec<String>,
    get_error: Option<StoreError>,
    set_error: Option<StoreError>,
}

#[derive(Clone, Default)]
struct FakeStore(Arc<Mutex<Inner>>);

impl SecretStore for FakeStore {
    fn get(&self, _service: &str, account: &str) -> Result<Option<String>, StoreError> {
        let g = self.0.lock().unwrap();
        if let Some(e) = g.get_error {
            return Err(e);
        }
        Ok(g.items.get(account).cloned())
    }

    fn set(&self, _service: &str, account: &str, value: &str) -> Result<(), StoreError> {
        let mut g = self.0.lock().unwrap();
        if let Some(e) = g.set_error {
            return Err(e);
        }
        g.sets.push(account.to_string());
        g.items.insert(account.to_string(), value.to_string());
        Ok(())
    }
}

fn dir(name: &str) -> PathBuf {
    let d = std::env::temp_dir().join(format!("arb-cred-{}-{name}", std::process::id()));
    let _ = std::fs::remove_dir_all(&d);
    std::fs::create_dir_all(&d).unwrap();
    d
}

// Deterministic, recognisable "random" bytes.
fn rand(n: usize) -> std::io::Result<Vec<u8>> {
    Ok((0..n)
        .map(|i| (i as u8).wrapping_mul(7).wrapping_add(3))
        .collect())
}

#[test]
fn first_run_generates_both_stores_them_and_hands_out_refs_only() {
    let store = FakeStore::default();
    let d = dir("first");

    let env = prepare(&store, &d, &rand);

    let g = store.0.lock().unwrap();
    assert_eq!(g.items.len(), 2);
    let cloak = g.items.get(CLOAK_ACCOUNT).unwrap();
    let skb = g.items.get(SECRET_KEY_BASE_ACCOUNT).unwrap();
    assert_eq!(cloak.len(), 44, "base64 of 32 bytes");
    assert!(cloak.ends_with('='));
    assert_eq!(skb.len(), 128, "64 bytes as hex");

    // Only refs reach the release environment.
    assert_eq!(env, ref_env());
    for (_, v) in &env {
        assert!(v.starts_with("keychain:"));
        assert!(!v.contains(cloak.as_str()) && !v.contains(skb.as_str()));
    }
    assert_eq!(
        env[0],
        (
            "WARDMAST_CLOAK_KEY_REF".to_string(),
            format!("keychain:{SERVICE}#cloak-key")
        )
    );
    assert_eq!(env[1].1, keychain_ref("secret-key-base"));

    // The data dir holds account names, never a value.
    for entry in std::fs::read_dir(&d).unwrap() {
        let body = std::fs::read_to_string(entry.unwrap().path()).unwrap();
        assert!(!body.contains(cloak.as_str()) && !body.contains(skb.as_str()));
    }
    let marker = std::fs::read_to_string(d.join("keychain-items")).unwrap();
    assert_eq!(
        marker.lines().collect::<Vec<_>>(),
        ["cloak-key", "secret-key-base"]
    );
}

#[test]
fn second_run_keeps_the_existing_keys() {
    let store = FakeStore::default();
    let d = dir("second");
    ensure(&store, &d, &rand).unwrap();
    let before = store.0.lock().unwrap().items.clone();

    ensure(&store, &d, &|_| panic!("must not generate again")).unwrap();

    let g = store.0.lock().unwrap();
    assert_eq!(g.items, before);
    assert_eq!(g.sets.len(), 2);
}

#[test]
fn an_item_deleted_after_creation_is_reported_never_regenerated() {
    let store = FakeStore::default();
    let d = dir("deleted");
    ensure(&store, &d, &rand).unwrap();
    store.0.lock().unwrap().items.remove(CLOAK_ACCOUNT);

    let err = ensure(&store, &d, &|_| panic!("must not generate")).unwrap_err();

    assert_eq!(
        err,
        CredentialError::Missing {
            item: format!("{SERVICE}#cloak-key")
        }
    );
    assert!(err.to_string().contains("dev.arbiter.wardmast#cloak-key"));
    assert!(err.to_string().contains("unreadable"));
    let g = store.0.lock().unwrap();
    assert!(!g.items.contains_key(CLOAK_ACCOUNT));
    assert_eq!(g.sets.len(), 2, "nothing new was written");
}

#[test]
fn a_locked_or_unreachable_keychain_is_not_a_missing_item() {
    for (failure, expect_locked) in [(StoreError::Locked, true), (StoreError::Unavailable, false)] {
        let store = FakeStore::default();
        store.0.lock().unwrap().get_error = Some(failure);
        let d = dir(if expect_locked { "locked" } else { "unavail" });

        let err = ensure(&store, &d, &|_| panic!("must not generate")).unwrap_err();

        assert_eq!(matches!(err, CredentialError::Locked { .. }), expect_locked);
        assert!(err.to_string().contains("dev.arbiter.wardmast#cloak-key"));
        assert!(store.0.lock().unwrap().sets.is_empty());

        // The release is still handed the refs, so its boot error is the one shown.
        assert_eq!(prepare(&store, &d, &|_| panic!("no")), ref_env());
    }
}

#[test]
fn a_failed_store_records_nothing_so_the_next_run_can_retry() {
    let store = FakeStore::default();
    store.0.lock().unwrap().set_error = Some(StoreError::Failed);
    let d = dir("setfail");

    assert!(matches!(
        ensure(&store, &d, &rand),
        Err(CredentialError::StoreFailed { .. })
    ));
    assert!(!d.join("keychain-items").exists());

    store.0.lock().unwrap().set_error = None;
    ensure(&store, &d, &rand).unwrap();
}

#[test]
fn an_item_the_shell_did_not_create_is_adopted_not_replaced() {
    let store = FakeStore::default();
    store
        .0
        .lock()
        .unwrap()
        .items
        .insert(CLOAK_ACCOUNT.into(), "restored-from-backup".into());
    let d = dir("adopt");

    ensure(&store, &d, &rand).unwrap();

    let g = store.0.lock().unwrap();
    assert_eq!(g.items[CLOAK_ACCOUNT], "restored-from-backup");
    assert_eq!(g.sets, [SECRET_KEY_BASE_ACCOUNT]);
}

#[test]
fn no_value_in_any_error_or_debug_output() {
    let store = FakeStore::default();
    let d = dir("redact");
    ensure(&store, &d, &rand).unwrap();
    let secret = store.0.lock().unwrap().items[CLOAK_ACCOUNT].clone();

    let out = CmdOutput {
        code: 0,
        stdout: secret.clone(),
        stderr: String::new(),
    };
    assert!(!format!("{out:?}").contains(&secret));

    store.0.lock().unwrap().items.remove(CLOAK_ACCOUNT);
    let err = ensure(&store, &d, &rand).unwrap_err();
    assert!(!format!("{err} {err:?}").contains(&secret));
}

#[test]
fn base64_matches_the_standard_vectors() {
    assert_eq!(base64(b""), "");
    assert_eq!(base64(b"M"), "TQ==");
    assert_eq!(base64(b"Ma"), "TWE=");
    assert_eq!(base64(b"Man"), "TWFu");
    assert_eq!(base64(b"foobar"), "Zm9vYmFy");
}

// ---- the platform stores, with a stubbed command runner ----------------------

type Calls = Arc<Mutex<Vec<(String, Vec<String>, Option<String>)>>>;

fn stub(
    os: Os,
    reply: impl Fn(&str, &[String]) -> std::io::Result<CmdOutput> + Send + Sync + 'static,
) -> (OsStore, Calls) {
    let calls: Calls = Arc::default();
    let rec = Arc::clone(&calls);
    let store = OsStore::with_runner(
        os,
        Box::new(move |program, args, stdin| {
            rec.lock()
                .unwrap()
                .push((program.to_string(), args.to_vec(), stdin.map(String::from)));
            reply(program, args)
        }),
    );
    (store, calls)
}

fn ok(stdout: &str) -> std::io::Result<CmdOutput> {
    Ok(CmdOutput {
        code: 0,
        stdout: stdout.into(),
        stderr: String::new(),
    })
}

fn fail(code: i32, stderr: &str) -> std::io::Result<CmdOutput> {
    Ok(CmdOutput {
        code,
        stdout: String::new(),
        stderr: stderr.into(),
    })
}

#[test]
fn macos_reads_with_security_and_writes_over_stdin() {
    let (store, calls) = stub(Os::MacOs, |_, _| ok("the-value\n"));
    assert_eq!(
        store.get(SERVICE, "cloak-key"),
        Ok(Some("the-value".into()))
    );
    store
        .set(SERVICE, "cloak-key", "TOP+SECRET/value==")
        .unwrap();

    let calls = calls.lock().unwrap();
    let (program, args, stdin) = &calls[0];
    assert_eq!(program, "security");
    assert_eq!(
        args,
        &[
            "find-generic-password",
            "-s",
            SERVICE,
            "-a",
            "cloak-key",
            "-w"
        ]
    );
    assert!(stdin.is_none());

    let (program, args, stdin) = &calls[1];
    assert_eq!(program, "security");
    assert_eq!(args, &["-i"]);
    let line = stdin.as_deref().unwrap();
    assert!(line.starts_with("add-generic-password -U -s dev.arbiter.wardmast -a cloak-key"));
    assert!(line.contains("TOP+SECRET/value=="));
    // The value is on stdin only.
    assert!(calls
        .iter()
        .all(|(_, a, _)| a.iter().all(|x| !x.contains("TOP+SECRET"))));
}

#[test]
fn linux_reads_with_secret_tool_and_writes_over_stdin() {
    let (store, calls) = stub(Os::Linux, |_, _| ok("the-value\n"));
    assert_eq!(
        store.get(SERVICE, "cloak-key"),
        Ok(Some("the-value".into()))
    );
    store.set(SERVICE, "secret-key-base", "TOP-SECRET").unwrap();

    let calls = calls.lock().unwrap();
    let (program, args, _) = &calls[0];
    assert_eq!(program, "secret-tool");
    assert_eq!(
        args,
        &["lookup", "service", SERVICE, "account", "cloak-key"]
    );

    let (program, args, stdin) = &calls[1];
    assert_eq!(program, "secret-tool");
    assert_eq!(args[0], "store");
    assert_eq!(stdin.as_deref(), Some("TOP-SECRET"));
    assert!(calls
        .iter()
        .all(|(_, a, _)| a.iter().all(|x| !x.contains("TOP-SECRET"))));
}

#[test]
fn only_an_unambiguous_missing_answer_is_none() {
    let out = |code, stderr: &str| CmdOutput {
        code,
        stdout: String::new(),
        stderr: stderr.into(),
    };
    assert_eq!(
        classify_get(Os::MacOs, &out(44, "could not be found")),
        Ok(None)
    );
    assert_eq!(classify_get(Os::Linux, &out(1, "")), Ok(None));

    assert_eq!(
        classify_get(Os::MacOs, &out(36, "User interaction is not allowed.")),
        Err(StoreError::Locked)
    );
    assert_eq!(
        classify_get(Os::MacOs, &out(51, "")),
        Err(StoreError::Locked)
    );
    assert_eq!(
        classify_get(Os::Linux, &out(1, "Cannot get secret of a locked object")),
        Err(StoreError::Locked)
    );
    assert_eq!(
        classify_get(Os::Linux, &out(1, "Cannot autolaunch D-Bus without X11")),
        Err(StoreError::Unavailable)
    );
    assert_eq!(
        classify_get(Os::Linux, &out(2, "something odd")),
        Err(StoreError::Failed)
    );
    assert_eq!(
        classify_get(Os::MacOs, &out(1, "something odd")),
        Err(StoreError::Failed)
    );
    // An existing but empty item is never "missing".
    assert_eq!(
        classify_get(
            Os::Linux,
            &CmdOutput {
                code: 0,
                stdout: "\n".into(),
                stderr: String::new()
            }
        ),
        Err(StoreError::Failed)
    );
}

#[test]
fn a_missing_tool_is_unavailable_not_missing() {
    for os in [Os::MacOs, Os::Linux] {
        let (store, _) = stub(os, |_, _| {
            Err(std::io::Error::from(std::io::ErrorKind::NotFound))
        });
        assert_eq!(
            store.get(SERVICE, "cloak-key"),
            Err(StoreError::Unavailable)
        );
        assert_eq!(
            store.set(SERVICE, "cloak-key", "v"),
            Err(StoreError::Unavailable)
        );
    }
}

#[test]
fn a_locked_store_write_is_locked() {
    let (store, _) = stub(Os::Linux, |_, _| {
        fail(
            1,
            "secret-tool: Cannot create an item in a locked collection",
        )
    });
    assert_eq!(
        store.set(SERVICE, "cloak-key", "v"),
        Err(StoreError::Locked)
    );
}

#[test]
fn odd_service_or_account_names_are_refused_before_anything_runs() {
    let (store, calls) = stub(Os::MacOs, |_, _| ok(""));
    assert_eq!(store.set("a b", "cloak-key", "v"), Err(StoreError::Failed));
    assert_eq!(store.set(SERVICE, "x; rm", "v"), Err(StoreError::Failed));
    assert!(calls.lock().unwrap().is_empty());
}

#[test]
fn a_store_that_does_not_persist_is_not_recorded_as_created() {
    let items: Arc<Mutex<HashMap<String, String>>> = Arc::default();
    let shared = Arc::clone(&items);
    let (store, calls) = stub(Os::Linux, move |_, args| {
        let m = shared.lock().unwrap();
        match args[0].as_str() {
            "lookup" => match m.get(&args[4]) {
                Some(v) => ok(v),
                None => fail(1, ""),
            },
            _ => ok(""),
        }
    });
    // `store` calls are recorded but the stub above does not persist them, so the
    // read-back fails: nothing may be recorded as created.
    let d = dir("e2e");
    assert!(matches!(
        ensure(&store, &d, &rand),
        Err(CredentialError::StoreFailed { .. })
    ));
    assert!(!d.join("keychain-items").exists());
    assert_eq!(calls.lock().unwrap()[1].1[0], "store");
}

#[test]
fn an_existing_service_install_is_never_given_a_second_cloak_key() {
    let store = FakeStore::default();
    let d = dir("existing");
    std::fs::write(d.join("wardmast.env"), "WARDMAST_CLOAK_KEY_REF=aws-sm:x\n").unwrap();

    let err = ensure(&store, &d, &|_| panic!("must not generate")).unwrap_err();

    assert!(matches!(err, CredentialError::Local { .. }));
    assert!(err.to_string().contains("already has an encryption key"));
    assert!(store.0.lock().unwrap().sets.is_empty());
}

#[test]
fn refs_the_operator_already_set_are_left_alone_and_the_keychain_is_not_touched() {
    // A deployment (or the CI smoke test, which has no Secret Service) points
    // the release at its own secrets; the shell must not override them or
    // generate keychain items next to them.
    let store = FakeStore::default();
    store.0.lock().unwrap().get_error = Some(StoreError::Unavailable);
    let d = dir("operator-refs");
    let set = |name: &str| match name {
        "WARDMAST_CLOAK_KEY_REF" => Some("file:/k/cloak".to_string()),
        "SECRET_KEY_BASE_REF" => Some("file:/k/skb".to_string()),
        _ => None,
    };

    let env = prepare_with(&store, &d, &|_| panic!("must not generate"), &set);

    assert!(env.is_empty(), "{env:?}");
    assert!(store.0.lock().unwrap().sets.is_empty());
}

#[test]
fn only_one_operator_ref_set_still_manages_both_through_the_keychain() {
    let store = FakeStore::default();
    let d = dir("one-ref");
    let set = |name: &str| (name == "SECRET_KEY_BASE_REF").then(|| "file:/k/skb".to_string());

    assert_eq!(prepare_with(&store, &d, &rand, &set), ref_env());
}
