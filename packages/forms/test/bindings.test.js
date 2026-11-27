import { test } from "node:test";
import assert from "node:assert/strict";
import { diffSplice } from "../dist/bindings.js";

// diffSplice: the one changed region between two strings, as a delete +
// insert at a single index. The element's text binding turns each input
// event into this splice against the Y.Text.

test("equal strings produce no splice", () => {
  assert.equal(diffSplice("hello", "hello"), null);
  assert.equal(diffSplice("", ""), null);
});

test("append and prepend", () => {
  assert.deepEqual(diffSplice("hello", "hello!"), { index: 5, deleteCount: 0, insert: "!" });
  assert.deepEqual(diffSplice("world", "Oi world"), { index: 0, deleteCount: 0, insert: "Oi " });
});

test("insert in the middle", () => {
  assert.deepEqual(diffSplice("hello world", "hello brave world"), { index: 6, deleteCount: 0, insert: "brave " });
});

test("delete in the middle", () => {
  assert.deepEqual(diffSplice("hello brave world", "hello world"), { index: 6, deleteCount: 6, insert: "" });
});

test("replace", () => {
  assert.deepEqual(diffSplice("hello world", "hello there"), { index: 6, deleteCount: 5, insert: "there" });
});

test("from and to empty", () => {
  assert.deepEqual(diffSplice("", "abc"), { index: 0, deleteCount: 0, insert: "abc" });
  assert.deepEqual(diffSplice("abc", ""), { index: 0, deleteCount: 3, insert: "" });
});

test("repeated characters keep the splice minimal", () => {
  // "aaa" -> "aaaa": one insert somewhere in the run, never a full rewrite.
  const change = diffSplice("aaa", "aaaa");
  assert.equal(change.deleteCount, 0);
  assert.equal(change.insert, "a");
});
