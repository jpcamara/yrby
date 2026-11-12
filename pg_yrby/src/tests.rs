use pgrx::prelude::*;

#[pg_schema]
mod tests {
    use pgrx::datum::DatumWithOid;
    use pgrx::prelude::*;
    use yrs::updates::decoder::Decode;
    use yrs::updates::encoder::Encode;
    use yrs::{Array, Doc, GetString, Map, ReadTxn, StateVector, Text, Transact, Update, XmlFragment, XmlTextPrelim};

    /// Successive edits by one client to text "t", each as its own update.
    fn edits(client: u64, parts: &[&str]) -> Vec<Vec<u8>> {
        let doc = Doc::with_client_id(client);
        let text = doc.get_or_insert_text("t");
        parts
            .iter()
            .map(|part| {
                let mut txn = doc.transact_mut();
                let len = text.len(&txn);
                text.insert(&mut txn, len, part);
                txn.encode_update_v1()
            })
            .collect()
    }

    fn arg(bytes: &[u8]) -> DatumWithOid<'static> {
        bytes.to_vec().into()
    }

    fn bytes(sql: &str, args: &[DatumWithOid]) -> Vec<u8> {
        Spi::get_one_with_args::<Vec<u8>>(sql, args).unwrap().expect("non-null")
    }

    fn text_of(sql: &str, args: &[DatumWithOid]) -> Option<String> {
        Spi::get_one_with_args::<String>(sql, args).unwrap()
    }

    fn flag(sql: &str, args: &[DatumWithOid]) -> bool {
        Spi::get_one_with_args::<bool>(sql, args).unwrap().unwrap()
    }

    /// Text "t" of a document, read with yrs directly.
    fn yrs_text(doc: &[u8]) -> String {
        let d = Doc::new();
        d.transact_mut().apply_update(Update::decode_v1(doc).unwrap()).unwrap();
        let t = d.get_or_insert_text("t");
        let s = t.get_string(&d.transact());
        s
    }

    #[pg_test]
    fn empty_doc_and_text_io_round_trip() {
        assert_eq!(text_of("select ydoc()::text", &[]).unwrap(), "\\x0000");
        assert!(flag("select '\\x0000'::ydoc = ydoc()", &[]));
        let u = &edits(1, &["hi"])[0];
        assert!(flag("select $1::ydoc::text::ydoc::bytea = $1", &[arg(u)]));
    }

    #[pg_test(error = "pg_yrby: ydoc input must be bytea hex (\\x...)")]
    fn text_input_must_be_hex() {
        Spi::run("select 'hello'::ydoc").unwrap();
    }

    #[pg_test]
    #[should_panic]
    fn cast_rejects_garbage() {
        Spi::run("select '\\xdeadbeef'::bytea::ydoc").unwrap();
    }

    #[pg_test]
    fn apply_builds_a_document_from_null() {
        let u = edits(1, &["hello", " world"]);
        let doc = bytes(
            "select ydoc_apply(ydoc_apply(null, $1), $2)::bytea",
            &[arg(&u[0]), arg(&u[1])],
        );
        assert_eq!(yrs_text(&doc), "hello world");
        assert_eq!(
            text_of("select ydoc_text($1::ydoc, 't')", &[arg(&doc)]).unwrap(),
            "hello world"
        );
        assert_eq!(text_of("select ydoc_text($1::ydoc, 'nope')", &[arg(&doc)]), None);
    }

    #[pg_test]
    fn apply_of_a_known_update_returns_the_same_value() {
        let u = edits(1, &["a", "b"]);
        let doc = bytes("select ydoc_apply(ydoc_apply(null, $1), $2)::bytea", &[arg(&u[0]), arg(&u[1])]);
        let again = bytes("select ydoc_apply($1::ydoc, $2)::bytea", &[arg(&doc), arg(&u[0])]);
        assert_eq!(doc, again, "a retried update must not change the stored bytes");
        assert!(!flag("select ydoc_adds($1::ydoc, $2)", &[arg(&doc), arg(&u[1])]));
        let more = edits(2, &["c"]);
        assert!(flag("select ydoc_adds($1::ydoc, $2)", &[arg(&doc), arg(&more[0])]));
    }

    #[pg_test]
    fn a_redundant_delete_does_not_add_but_a_new_one_does() {
        let doc = Doc::with_client_id(1);
        let text = doc.get_or_insert_text("t");
        text.insert(&mut doc.transact_mut(), 0, "abc");
        let base = doc.transact().encode_state_as_update_v1(&StateVector::default());
        let del = {
            let mut txn = doc.transact_mut();
            text.remove_range(&mut txn, 0, 1);
            txn.encode_update_v1()
        };
        let stored = bytes("select ydoc_apply(ydoc_apply(null, $1), $2)::bytea", &[arg(&base), arg(&del)]);
        assert_eq!(yrs_text(&stored), "bc");
        assert!(!flag("select ydoc_adds($1::ydoc, $2)", &[arg(&stored), arg(&del)]));
        assert!(flag("select ydoc_adds($1::ydoc, $2)", &[arg(&base), arg(&del)]));
    }

    #[pg_test]
    fn state_vector_and_diff_sync_a_client() {
        let u = edits(1, &["one", " two", " three"]);
        let server = bytes(
            "select ydoc_merge_agg(u)::bytea from unnest(array[$1, $2, $3]) u",
            &[arg(&u[0]), arg(&u[1]), arg(&u[2])],
        );
        // A client that has only the first edit.
        let client = Doc::new();
        client.transact_mut().apply_update(Update::decode_v1(&u[0]).unwrap()).unwrap();
        let sv = client.transact().state_vector().encode_v1();
        let missing = bytes("select ydoc_diff($1::ydoc, $2)", &[arg(&server), arg(&sv)]);
        assert!(missing.len() < server.len());
        client.transact_mut().apply_update(Update::decode_v1(&missing).unwrap()).unwrap();
        let t = client.get_or_insert_text("t");
        assert_eq!(t.get_string(&client.transact()), "one two three");

        // The server's state vector covers the client's; the full diff equals the doc.
        let server_sv = bytes("select ydoc_state_vector($1::ydoc)", &[arg(&server)]);
        assert_eq!(server_sv, client.transact().state_vector().encode_v1());
        let full = bytes("select ydoc_diff($1::ydoc)", &[arg(&server)]);
        assert_eq!(yrs_text(&full), "one two three");
    }

    #[pg_test]
    fn merge_agg_matches_applying_one_by_one_in_any_order() {
        let a = edits(1, &["a1", "a2", "a3"]);
        let b = edits(2, &["b1", "b2"]);
        let all: Vec<&Vec<u8>> = a.iter().chain(b.iter()).collect();
        let args: Vec<DatumWithOid> = all.iter().map(|u| arg(u)).collect();
        let merged = bytes(
            "select ydoc_merge_agg(u)::bytea from unnest(array[$1, $2, $3, $4, $5]) u",
            &args,
        );
        let reversed = bytes(
            "select ydoc_merge_agg(u order by o desc)::bytea from unnest(array[$1, $2, $3, $4, $5]) with ordinality x(u, o)",
            &args,
        );
        let mut applied: Option<Vec<u8>> = None;
        for u in &all {
            applied = Some(match applied {
                None => bytes("select ydoc_apply(null, $1)::bytea", &[arg(u)]),
                Some(d) => bytes("select ydoc_apply($1::ydoc, $2)::bytea", &[arg(&d), arg(u)]),
            });
        }
        let applied = applied.unwrap();
        assert!(flag("select $1::ydoc = $2::ydoc", &[arg(&merged), arg(&applied)]));
        assert!(flag("select $1::ydoc = $2::ydoc", &[arg(&reversed), arg(&applied)]));
        assert_eq!(yrs_text(&merged), yrs_text(&applied));
        assert_eq!(
            bytes("select ydoc_state_vector($1::ydoc)", &[arg(&merged)]),
            bytes("select ydoc_state_vector($1::ydoc)", &[arg(&applied)])
        );
    }

    #[pg_test]
    fn merge_agg_over_many_rows_folds_in_batches() {
        let parts: Vec<String> = (0..600).map(|i| format!("{i},")).collect();
        let refs: Vec<&str> = parts.iter().map(String::as_str).collect();
        let u = edits(7, &refs);
        Spi::run("create temp table log (id serial, u bytea)").unwrap();
        for x in &u {
            Spi::run_with_args("insert into log (u) values ($1)", &[arg(x)]).unwrap();
        }
        let merged = bytes("select ydoc_merge_agg(u order by random())::bytea from log", &[]);
        assert_eq!(yrs_text(&merged), parts.concat());
        assert_eq!(
            Spi::get_one::<Vec<u8>>("select ydoc_merge_agg(u)::bytea from log where false").unwrap(),
            None
        );
    }

    #[pg_test]
    fn ydoc_merge_agg_accepts_documents() {
        let a = edits(1, &["x"]);
        let b = edits(2, &["y"]);
        let merged = bytes(
            "select ydoc_merge_agg(d)::bytea from (values ($1::ydoc), ($2::ydoc)) v(d)",
            &[arg(&a[0]), arg(&b[0])],
        );
        let text = yrs_text(&merged);
        assert!(text == "xy" || text == "yx", "{text}");
    }

    #[pg_test]
    fn pending_updates_are_kept_and_heal_but_never_served() {
        let x = edits(1, &["a", "b", "c"]);
        // "c" arrives without "b": it has to wait.
        let doc = bytes("select ydoc_apply(ydoc_apply(null, $1), $2)::bytea", &[arg(&x[0]), arg(&x[2])]);
        assert!(flag("select ydoc_has_pending($1::ydoc)", &[arg(&doc)]));
        assert_eq!(text_of("select ydoc_text($1::ydoc, 't')", &[arg(&doc)]).unwrap(), "a");
        let served = bytes("select ydoc_diff($1::ydoc)", &[arg(&doc)]);
        assert_eq!(yrs_text(&served), "a");
        let probe = Doc::new();
        probe.transact_mut().apply_update(Update::decode_v1(&served).unwrap()).unwrap();
        assert!(probe.transact().store().pending_update().is_none(), "diff must be gap-free");
        // "b" arrives and heals the gap.
        let healed = bytes("select ydoc_apply($1::ydoc, $2)::bytea", &[arg(&doc), arg(&x[1])]);
        assert!(!flag("select ydoc_has_pending($1::ydoc)", &[arg(&healed)]));
        assert_eq!(text_of("select ydoc_text($1::ydoc, 't')", &[arg(&healed)]).unwrap(), "abc");
        // A gapped update counts as adding something.
        assert!(flag("select ydoc_adds($1::ydoc, $2)", &[arg(&bytes("select ydoc_apply(null, $1)::bytea", &[arg(&x[0])])), arg(&x[2])]));
    }

    #[pg_test]
    fn diff_can_include_pending_so_a_peer_heals_too() {
        let x = edits(1, &["a", "b", "c"]);
        let doc = bytes("select ydoc_apply(ydoc_apply(null, $1), $2)::bytea", &[arg(&x[0]), arg(&x[2])]);
        // A peer that has "a" gets the waiting "c" as well.
        let sv = bytes("select ydoc_state_vector(ydoc_apply(null, $1))", &[arg(&x[0])]);
        let served = bytes("select ydoc_diff($1::ydoc, $2, include_pending => true)", &[arg(&doc), arg(&sv)]);
        let peer = Doc::new();
        peer.transact_mut().apply_update(Update::decode_v1(&x[0]).unwrap()).unwrap();
        peer.transact_mut().apply_update(Update::decode_v1(&served).unwrap()).unwrap();
        assert!(peer.transact().store().pending_update().is_some(), "the peer holds the gap");
        // When "b" reaches the peer, it heals there without asking again.
        peer.transact_mut().apply_update(Update::decode_v1(&x[1]).unwrap()).unwrap();
        assert_eq!(peer.get_or_insert_text("t").get_string(&peer.transact()), "abc");
        // Without a gap, both modes serve the same content.
        let healed = bytes("select ydoc_apply($1::ydoc, $2)::bytea", &[arg(&doc), arg(&x[1])]);
        assert_eq!(yrs_text(&bytes("select ydoc_diff($1::ydoc, null, true)", &[arg(&healed)])), "abc");
        assert_eq!(yrs_text(&bytes("select ydoc_diff($1::ydoc)", &[arg(&healed)])), "abc");
    }

    #[pg_test]
    fn merge_agg_keeps_a_gap_for_later() {
        let x = edits(1, &["a", "b", "c"]);
        let merged = bytes(
            "select ydoc_merge_agg(u)::bytea from unnest(array[$1, $2]) u",
            &[arg(&x[0]), arg(&x[2])],
        );
        let healed = bytes("select ydoc_apply($1::ydoc, $2)::bytea", &[arg(&merged), arg(&x[1])]);
        assert_eq!(yrs_text(&healed), "abc");
    }

    #[pg_test]
    fn equality_is_about_content_not_bytes() {
        let a = edits(1, &["a", "b"]);
        let one_by_one = bytes("select ydoc_apply(ydoc_apply(null, $1), $2)::bytea", &[arg(&a[0]), arg(&a[1])]);
        let merged = bytes("select ydoc_merge(ydoc($1), ydoc($2))::bytea", &[arg(&a[0]), arg(&a[1])]);
        assert!(flag("select $1::ydoc = $2::ydoc", &[arg(&one_by_one), arg(&merged)]));
        assert!(flag("select $1::ydoc <> $2::ydoc", &[arg(&one_by_one), arg(&a[0])]));
    }

    #[pg_test]
    fn reads_maps_arrays_xml_and_json() {
        let doc = Doc::with_client_id(3);
        let (meta, list, t, frag) = (
            doc.get_or_insert_map("meta"),
            doc.get_or_insert_array("tags"),
            doc.get_or_insert_text("body"),
            doc.get_or_insert_xml_fragment("prosemirror"),
        );
        {
            let mut txn = doc.transact_mut();
            meta.insert(&mut txn, "title", "Notes");
            meta.insert(&mut txn, "n", 2);
            list.push_back(&mut txn, "a");
            list.push_back(&mut txn, 1);
            t.insert(&mut txn, 0, "héllo 👋");
            let xt = frag.push_back(&mut txn, XmlTextPrelim::new("para"));
            let _ = xt;
        }
        let u = doc.transact().encode_state_as_update_v1(&StateVector::default());
        assert_eq!(
            text_of("select ydoc_map($1::ydoc, 'meta')::text", &[arg(&u)]).unwrap(),
            r#"{"n": 2, "title": "Notes"}"#
        );
        assert_eq!(text_of("select ydoc_array($1::ydoc, 'tags')::text", &[arg(&u)]).unwrap(), r#"["a", 1]"#);
        assert_eq!(text_of("select ydoc_text($1::ydoc, 'body')", &[arg(&u)]).unwrap(), "héllo 👋");
        assert_eq!(text_of("select ydoc_xml($1::ydoc, 'prosemirror')", &[arg(&u)]).unwrap(), "para");
        // Root types are inferred from content. An XML fragment of nested
        // types looks like an array of them; read XML with ydoc_xml instead.
        assert!(flag(
            r#"select ydoc_json($1::ydoc) = '{"meta": {"n": 2, "title": "Notes"}, "tags": ["a", 1], "body": "héllo 👋", "prosemirror": ["para"]}'::jsonb"#,
            &[arg(&u)]
        ));
    }

    #[pg_test]
    fn snapshot_plus_log_compacts_into_the_snapshot_keeping_gaps() {
        let x = edits(1, &["a", "b", "c"]);
        let y = edits(2, &["y"]);
        Spi::run("create temp table snap (id int primary key, body ydoc not null)").unwrap();
        Spi::run("create temp table log (id bigserial primary key, doc_id int not null, u bytea not null)").unwrap();
        Spi::run("insert into snap values (1, ydoc())").unwrap();
        // "b" is missing, so "c" has to wait.
        for u in [&x[0], &y[0], &x[2]] {
            Spi::run_with_args("insert into log (doc_id, u) values (1, $1)", &[arg(u)]).unwrap();
        }
        let compact = "with folded as (delete from log where doc_id = 1 returning u)
                       update snap set body = ydoc_apply(body, (select ydoc_merge_agg(u)::bytea from folded)) where id = 1";
        Spi::run(compact).unwrap();
        assert_eq!(Spi::get_one::<i64>("select count(*) from log").unwrap(), Some(0));
        assert!(flag("select ydoc_has_pending(body) from snap", &[]));
        let served = bytes("select ydoc_diff(body) from snap", &[]);
        let t = yrs_text(&served);
        assert!(t == "ay" || t == "ya", "{t}");
        // "b" arrives in the log; the read merges snapshot and log.
        Spi::run_with_args("insert into log (doc_id, u) values (1, $1)", &[arg(&x[1])]).unwrap();
        let read = bytes(
            "select ydoc_merge_agg(p)::bytea from (select body::bytea p from snap union all select u from log) t",
            &[],
        );
        assert!(!flag("select ydoc_has_pending($1::ydoc)", &[arg(&read)]));
        Spi::run(compact).unwrap();
        let t = text_of("select ydoc_text(body, 't') from snap", &[]).unwrap();
        assert!(t == "abcy" || t == "yabc", "{t}");
        assert!(!flag("select ydoc_has_pending(body) from snap", &[]));
    }

    #[pg_test]
    fn works_as_a_column_with_null_and_update() {
        let u = edits(1, &["x", "y"]);
        Spi::run("create temp table notes (id int primary key, body ydoc)").unwrap();
        Spi::run("insert into notes values (1, null)").unwrap();
        for x in &u {
            Spi::run_with_args("update notes set body = ydoc_apply(body, $1) where id = 1", &[arg(x)]).unwrap();
        }
        assert_eq!(text_of("select ydoc_text(body, 't') from notes", &[]).unwrap(), "xy");
        assert_eq!(text_of("select ydoc_json(body)->>'t' from notes", &[]).unwrap(), "xy");
    }

    /// Update orders from tests/js/converge.mjs that broke a yrs `Doc`
    /// applying them one by one, and yrby-core's compaction plan.
    fn out_of_order_fixtures() -> Vec<(String, Vec<Vec<u8>>, String)> {
        let dir = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fixtures/out-of-order");
        let mut out = Vec::new();
        for entry in std::fs::read_dir(dir).unwrap() {
            let path = entry.unwrap().path();
            if path.extension().is_some_and(|e| e == "hex") {
                let updates = std::fs::read_to_string(&path)
                    .unwrap()
                    .lines()
                    .filter(|l| !l.is_empty())
                    .map(|l| (0..l.len()).step_by(2).map(|i| u8::from_str_radix(&l[i..i + 2], 16).unwrap()).collect())
                    .collect();
                let json = std::fs::read_to_string(path.with_extension("json")).unwrap();
                out.push((path.display().to_string(), updates, json));
            }
        }
        assert!(out.len() >= 10);
        out
    }

    #[pg_test]
    fn out_of_order_fixtures_converge_through_apply_and_compaction() {
        for (name, updates, json) in out_of_order_fixtures() {
            let expected: serde_json::Value = serde_json::from_str(&json).unwrap();
            let body = expected["body"].as_str().unwrap();
            // One update at a time, in the order that broke yrs.
            let mut doc = crate::ycore::EMPTY.to_vec();
            for u in &updates {
                if let Some(next) = crate::ycore::apply(&doc, u).unwrap() {
                    doc = next;
                }
            }
            assert!(!crate::ycore::pending(&doc).unwrap(), "{name}: pending left after apply");
            assert_eq!(crate::ycore::text(&doc, "body").unwrap().as_deref(), Some(body), "{name}");
            // Snapshot + log, compacting every 7 rows; nothing may be lost.
            let mut snap = crate::ycore::EMPTY.to_vec();
            let mut log: Vec<Vec<u8>> = Vec::new();
            for (i, u) in updates.iter().enumerate() {
                log.push(u.clone());
                if i % 7 == 6 {
                    let folded = crate::ycore::merge(&log).unwrap();
                    snap = crate::ycore::apply(&snap, &folded).unwrap().unwrap_or(snap);
                    log.clear();
                }
            }
            let folded = crate::ycore::merge(&log).unwrap();
            snap = crate::ycore::apply(&snap, &folded).unwrap().unwrap_or(snap);
            assert!(!crate::ycore::pending(&snap).unwrap(), "{name}: pending left after compaction");
            assert_eq!(crate::ycore::text(&snap, "body").unwrap().as_deref(), Some(body), "{name}");
            assert!(crate::ycore::equal(&snap, &doc).unwrap(), "{name}");
        }
    }
}
