// yrs Fixture Generator for yrb-lite interop testing
// Build with: cargo build --release
// Run with: ./target/release/yrs_generator [command] [args...]

use base64::{engine::general_purpose::STANDARD, Engine};
use serde_json::json;
use std::env;
use yrs::updates::decoder::Decode;
use yrs::updates::encoder::Encode;
use yrs::{Doc, GetString, ReadTxn, StateVector, Text, Transact, Update};

fn to_base64(bytes: &[u8]) -> String {
    STANDARD.encode(bytes)
}

fn from_base64(s: &str) -> Vec<u8> {
    STANDARD.decode(s).expect("Invalid base64")
}

fn main() {
    let args: Vec<String> = env::args().collect();

    if args.len() < 2 {
        eprintln!("Usage: yrs_generator <command> [args...]");
        eprintln!("Commands: create-doc, empty-doc, apply-update, diff-update, merge-updates, get-text, verify-sv, version");
        std::process::exit(1);
    }

    let command = &args[1];
    let result = match command.as_str() {
        "create-doc" => {
            if args.len() < 5 {
                eprintln!("Usage: create-doc <client_id> <field_name> <content>");
                std::process::exit(1);
            }
            create_doc(&args[2], &args[3], &args[4])
        }
        "empty-doc" => {
            let client_id = args.get(2).map(|s| s.as_str()).unwrap_or("1");
            empty_doc(client_id)
        }
        "apply-update" => {
            if args.len() < 3 {
                eprintln!("Usage: apply-update <base64_update> [client_id]");
                std::process::exit(1);
            }
            let client_id = args.get(3).map(|s| s.as_str()).unwrap_or("1");
            apply_update(&args[2], client_id)
        }
        "diff-update" => {
            if args.len() < 4 {
                eprintln!("Usage: diff-update <base64_doc_update> <base64_state_vector>");
                std::process::exit(1);
            }
            diff_update(&args[2], &args[3])
        }
        "merge-updates" => {
            if args.len() < 4 {
                eprintln!("Usage: merge-updates <base64_update1> <base64_update2>");
                std::process::exit(1);
            }
            merge_updates(&args[2], &args[3])
        }
        "get-text" => {
            if args.len() < 4 {
                eprintln!("Usage: get-text <base64_update> <field_name>");
                std::process::exit(1);
            }
            get_text(&args[2], &args[3])
        }
        "verify-sv" => {
            if args.len() < 4 {
                eprintln!("Usage: verify-sv <base64_sv1> <base64_sv2>");
                std::process::exit(1);
            }
            verify_sv(&args[2], &args[3])
        }
        "version" => {
            println!("{}", json!({"runtime": "yrs", "version": "0.21"}));
            return;
        }
        _ => {
            eprintln!("Unknown command: {}", command);
            std::process::exit(1);
        }
    };

    println!("{}", result);
}

fn create_doc(client_id: &str, field_name: &str, content: &str) -> String {
    let client_id: u64 = client_id.parse().expect("Invalid client_id");
    let doc = Doc::with_client_id(client_id);
    let text = doc.get_or_insert_text(field_name);
    {
        let mut txn = doc.transact_mut();
        text.push(&mut txn, content);
    }
    let txn = doc.transact();
    let update = txn.encode_state_as_update_v1(&StateVector::default());
    let sv = txn.state_vector().encode_v1();

    json!({
        "update": to_base64(&update),
        "state_vector": to_base64(&sv),
        "client_id": client_id
    })
    .to_string()
}

fn empty_doc(client_id: &str) -> String {
    let client_id: u64 = client_id.parse().expect("Invalid client_id");
    let doc = Doc::with_client_id(client_id);
    let txn = doc.transact();
    let update = txn.encode_state_as_update_v1(&StateVector::default());
    let sv = txn.state_vector().encode_v1();

    json!({
        "update": to_base64(&update),
        "state_vector": to_base64(&sv),
        "client_id": client_id
    })
    .to_string()
}

fn apply_update(base64_update: &str, client_id: &str) -> String {
    let client_id: u64 = client_id.parse().expect("Invalid client_id");
    let update_bytes = from_base64(base64_update);
    let update = Update::decode_v1(&update_bytes).expect("Invalid update");

    let doc = Doc::with_client_id(client_id);
    {
        let mut txn = doc.transact_mut();
        txn.apply_update(update).expect("Failed to apply update");
    }

    let txn = doc.transact();
    let new_update = txn.encode_state_as_update_v1(&StateVector::default());
    let sv = txn.state_vector().encode_v1();

    json!({
        "update": to_base64(&new_update),
        "state_vector": to_base64(&sv),
        "client_id": client_id
    })
    .to_string()
}

fn diff_update(base64_doc_update: &str, base64_state_vector: &str) -> String {
    let update_bytes = from_base64(base64_doc_update);
    let sv_bytes = from_base64(base64_state_vector);

    let update = Update::decode_v1(&update_bytes).expect("Invalid update");
    let sv = StateVector::decode_v1(&sv_bytes).expect("Invalid state vector");

    let doc = Doc::new();
    {
        let mut txn = doc.transact_mut();
        txn.apply_update(update).expect("Failed to apply update");
    }

    let txn = doc.transact();
    let diff = txn.encode_state_as_update_v1(&sv);

    json!({
        "diff_update": to_base64(&diff)
    })
    .to_string()
}

fn merge_updates(base64_update1: &str, base64_update2: &str) -> String {
    let update1_bytes = from_base64(base64_update1);
    let update2_bytes = from_base64(base64_update2);

    let update1 = Update::decode_v1(&update1_bytes).expect("Invalid update1");
    let update2 = Update::decode_v1(&update2_bytes).expect("Invalid update2");

    let doc = Doc::new();
    {
        let mut txn = doc.transact_mut();
        txn.apply_update(update1).expect("Failed to apply update1");
        txn.apply_update(update2).expect("Failed to apply update2");
    }

    let txn = doc.transact();
    let merged = txn.encode_state_as_update_v1(&StateVector::default());
    let sv = txn.state_vector().encode_v1();

    json!({
        "merged_update": to_base64(&merged),
        "state_vector": to_base64(&sv)
    })
    .to_string()
}

fn get_text(base64_update: &str, field_name: &str) -> String {
    let update_bytes = from_base64(base64_update);
    let update = Update::decode_v1(&update_bytes).expect("Invalid update");

    let doc = Doc::new();
    {
        let mut txn = doc.transact_mut();
        txn.apply_update(update).expect("Failed to apply update");
    }

    let text = doc.get_or_insert_text(field_name);
    let txn = doc.transact();
    let content = text.get_string(&txn);
    let length = text.len(&txn);

    json!({
        "content": content,
        "length": length
    })
    .to_string()
}

fn verify_sv(base64_sv1: &str, base64_sv2: &str) -> String {
    let sv1_bytes = from_base64(base64_sv1);
    let sv2_bytes = from_base64(base64_sv2);

    let sv1 = StateVector::decode_v1(&sv1_bytes).expect("Invalid sv1");
    let sv2 = StateVector::decode_v1(&sv2_bytes).expect("Invalid sv2");

    // StateVectors are equal if they have the same clocks for all clients
    let match_result = sv1 == sv2;

    json!({
        "match": match_result
    })
    .to_string()
}
