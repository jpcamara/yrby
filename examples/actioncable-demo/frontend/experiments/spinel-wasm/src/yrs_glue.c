/* The few yffi calls Ruby can't make through ffi_func: YInput and YOptions
   travel by value, owned strings and byte buffers have to be copied out and
   released, and the update observer runs inside a yrs commit, where Ruby
   should not be re-entered. Everything else in yrs.rb calls yffi directly. */
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include "libyrs.h"

/* A :binstr return reads its byte count from here (single-threaded runtime). */
extern int sp_ffi_bin_len;

/* Ruby copies a returned string at once, so one buffer serves every call. */
static char *held = 0;
static size_t held_size = 0;

static const char *hold(const char *bytes, size_t len) {
  if (len + 1 > held_size) {
    free(held);
    held_size = len * 2 + 64;
    held = malloc(held_size);
  }
  if (len) memcpy(held, bytes, len);
  held[len] = 0;
  sp_ffi_bin_len = (int)len;
  return held;
}

static const char *hold_string(char *owned, const char *fallback) {
  if (!owned) return hold(fallback, strlen(fallback));
  const char *copy = hold(owned, strlen(owned));
  ystring_destroy(owned);
  return copy;
}

/* An empty result means yffi refused the input (a malformed state vector). */
static const char *hold_binary(char *owned, uint32_t len) {
  if (!owned) return hold("", 0);
  const char *copy = hold(owned, len);
  ybinary_destroy(owned, len);
  return copy;
}

YDoc *yg_doc_new(uint32_t client_id) {
  YOptions options = yoptions();
  options.id = client_id;
  return ydoc_new_with_options(options);
}

/* Each committed transaction's update, in order, until Ruby takes it. The
   studio has one document, so one outbox serves it. */
typedef struct { char *bytes; uint32_t len; } Update;
static Update *outbox = 0;
static size_t outbox_head = 0, outbox_count = 0, outbox_size = 0;

static void observed(void *state, uint32_t len, const char *bytes) {
  (void)state;
  if (outbox_head + outbox_count == outbox_size) {
    memmove(outbox, outbox + outbox_head, outbox_count * sizeof(Update));
    outbox_head = 0;
    if (outbox_count == outbox_size) {
      outbox_size = outbox_size * 2 + 8;
      outbox = realloc(outbox, outbox_size * sizeof(Update));
    }
  }
  Update update = { malloc(len ? len : 1), len };
  memcpy(update.bytes, bytes, len);
  outbox[outbox_head + outbox_count++] = update;
}

void yg_observe_updates(YDoc *doc) {
  YTransaction *txn = ydoc_write_transaction(doc, 0, 0);
  ytransaction_observe_updates_v1(txn, 6, "outbox", 0, observed);
  ytransaction_commit(txn);
}

/* The oldest update not yet taken, or an empty string. */
const char *yg_take_update(void) {
  if (!outbox_count) return hold("", 0);
  Update update = outbox[outbox_head++];
  outbox_count--;
  const char *copy = hold(update.bytes, update.len);
  free(update.bytes);
  return copy;
}

const char *yg_state_vector(YTransaction *txn) {
  uint32_t len = 0;
  char *vector = ytransaction_state_vector_v1(txn, &len);
  return hold_binary(vector, len);
}

const char *yg_diff(YTransaction *txn, const char *vector, uint32_t vector_len) {
  uint32_t len = 0;
  char *update = ytransaction_state_diff_v1(txn, vector_len ? vector : 0, vector_len, &len);
  return hold_binary(update, len);
}

const char *yg_json(Branch *branch, YTransaction *txn) { return hold_string(ybranch_json(branch, txn), "{}"); }

const char *yg_get_json(Branch *map, YTransaction *txn, const char *key) {
  return hold_string(ymap_get_json(map, txn, key), "null");
}

void yg_set_int(Branch *map, YTransaction *txn, const char *key, int value) {
  YInput input = yinput_long(value);
  ymap_insert(map, txn, key, &input);
}

void yg_set_string(Branch *map, YTransaction *txn, const char *key, const char *value) {
  YInput input = yinput_string(value);
  ymap_insert(map, txn, key, &input);
}

void yg_set_bool(Branch *map, YTransaction *txn, const char *key, int value) {
  YInput input = yinput_bool(value ? Y_TRUE : Y_FALSE);
  ymap_insert(map, txn, key, &input);
}

/* An integral number as an int; anything else is the fallback. Yjs clients
   write small integers, but a float that holds one counts too. */
static int output_int(const YOutput *value, int fallback) {
  if (!value) return fallback;
  if (value->tag == Y_JSON_INT) return (int)value->value.integer;
  if (value->tag == Y_JSON_NUM && value->value.num == (double)(int)value->value.num) return (int)value->value.num;
  return fallback;
}

int yg_get_int(Branch *map, YTransaction *txn, const char *key, int fallback) {
  YOutput *value = ymap_get(map, txn, key);
  int result = output_int(value, fallback);
  if (value) youtput_destroy(value);
  return result;
}

const char *yg_entry_key(const YMapEntry *entry) { return entry->key; }
int yg_entry_int(const YMapEntry *entry, int fallback) { return output_int(entry->value, fallback); }

YUndoManager *yg_undo_manager(int capture_timeout) {
  YUndoManagerOptions options = { capture_timeout };
  return yundo_manager(&options);
}
