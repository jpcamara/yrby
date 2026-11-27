/*
 * yrby's Ruby binding as a plain C extension over a Rust staticlib (spike).
 * Marco Roth's pattern: Ruby's C API on this side, `extern "C"` functions
 * and a cbindgen header on the other (ffi/). No magnus, no rb-sys.
 *
 * The slice: Y::Doc (everything but the live handles other than Text, the
 * anchors and apply_update_changes), Y::Text, the Y codec functions, Y::Error
 * and the message constants.
 *
 * Rules this file keeps:
 * - Every Rust call goes through call(), which releases the GVL as the
 *   magnus build's nogvl() does: RB_NOGVL_INTR_FAIL, run with the GVL when
 *   an interrupt is pending, rb_thread_check_ints() after.
 * - Inputs can't change while the GVL is released: a small unfrozen string
 *   is copied to the stack, anything else crosses as a frozen view (no copy)
 *   that the reference on this stack keeps alive and pinned.
 * - Nothing raises while Rust owns memory: results are converted and freed
 *   before any rb_raise or interrupt check.
 */
#include <ruby.h>
#include <ruby/encoding.h>
#include <ruby/thread.h>
#include <string.h>
#include "include/yrby_ffi.h"

static VALUE mY, cDoc, cText, eError;

typedef struct YrbyResult (*yrby_fn)(const struct YrbyArgs *);

struct call {
  yrby_fn fn;
  struct YrbyArgs args;
  struct YrbyResult result;
  int ran;
};

static void *run_call(void *data) {
  struct call *c = data;
  c->result = c->fn(&c->args);
  c->ran = 1;
  return NULL;
}

static struct YrbyResult call(yrby_fn fn, struct YrbyArgs args) {
  struct call c = {fn, args, {0}, 0};
  rb_nogvl(run_call, &c, NULL, NULL, RB_NOGVL_INTR_FAIL);
  if (!c.ran) run_call(&c);
  return c.result;
}

/*
 * Raise for an error result, or return. Frees the message first, and lets a
 * pending interrupt go before the error, as the magnus build's nogvl does.
 */
static void check(struct YrbyResult r) {
  if (r.status != YRBY_STATUS_ERROR && r.status != YRBY_STATUS_PANIC) return;
  VALUE message = rb_utf8_str_new((const char *)r.ptr, (long)r.len);
  yrby_free(r.ptr, r.len);
  rb_thread_check_ints();
  rb_exc_raise(rb_exc_new_str(eError, message));
}

/* The bytes of a result as a String in `enc` (NULL: binary), or nil. */
static VALUE take_string(struct YrbyResult r, rb_encoding *enc) {
  if (r.status == YRBY_STATUS_NIL) return Qnil;
  VALUE s = enc ? rb_enc_str_new((const char *)r.ptr, (long)r.len, enc)
                : rb_str_new((const char *)r.ptr, (long)r.len);
  yrby_free(r.ptr, r.len);
  return s;
}

/*
 * Run `fn` and turn its result into a value. `kind` picks the conversion.
 * The interrupt check runs after the result is safe in Ruby's hands.
 */
enum kind { AS_BYTES, AS_TEXT, AS_BOOL, AS_INT, AS_NIL };

static VALUE finish(struct YrbyResult r, enum kind kind) {
  check(r);
  VALUE out;
  switch (kind) {
    case AS_BYTES: out = take_string(r, NULL); break;
    case AS_TEXT: out = take_string(r, rb_utf8_encoding()); break;
    case AS_BOOL: out = r.value ? Qtrue : Qfalse; break;
    case AS_INT: out = ULL2NUM(r.value); break;
    default: out = Qnil; break;
  }
  RB_GC_GUARD(out);
  rb_thread_check_ints();
  return out;
}

/*
 * `str`'s bytes, fixed while the GVL is released. A small unfrozen string is
 * copied into the caller's stack buffer (cheaper than a new object); anything
 * else gets a frozen view, which another thread can't change and the caller's
 * stack reference keeps alive and pinned.
 */
#define SMALL 1024
#define INPUT_BUF uint8_t buf[SMALL]

static VALUE frozen_bytes_into(VALUE str, struct YrbyArgs *args, uint8_t *buf) {
  StringValue(str);
  long len = RSTRING_LEN(str);
  if (buf && !OBJ_FROZEN(str) && len <= SMALL) {
    memcpy(buf, RSTRING_PTR(str), (size_t)len);
    args->ptr = buf;
    args->len = (size_t)len;
    return str;
  }
  VALUE view = rb_str_new_frozen(str);
  args->ptr = (const uint8_t *)RSTRING_PTR(view);
  args->len = (size_t)RSTRING_LEN(view);
  return view;
}
#define frozen_bytes(str, args) frozen_bytes_into((str), (args), buf)

/* Whether `str`'s bytes are valid UTF-8 as they stand (magnus's test_as_str). */
static int utf8_as_is(VALUE str) {
  int idx = ENCODING_GET(str);
  int cr = rb_enc_str_coderange(str);
  if (idx == rb_utf8_encindex() || idx == rb_usascii_encindex())
    return cr == ENC_CODERANGE_7BIT || cr == ENC_CODERANGE_VALID;
  return idx == rb_ascii8bit_encindex() && cr == ENC_CODERANGE_7BIT;
}

/*
 * As frozen_bytes, with the text in UTF-8 first. Same rules and errors as
 * magnus's RString#to_string: transcode if needed, else EncodingError.
 */
static VALUE frozen_utf8_into(VALUE str, struct YrbyArgs *args, uint8_t *buf) {
  StringValue(str);
  if (!utf8_as_is(str)) {
    str = rb_str_conv_enc(str, NULL, rb_utf8_encoding());
    if (!utf8_as_is(str)) {
      int idx = ENCODING_GET(str);
      if (idx == rb_utf8_encindex() || idx == rb_usascii_encindex())
        rb_raise(rb_eEncodingError, "invalid byte sequence in UTF-8");
      rb_raise(rb_eEncodingError, "expected utf-8, got %s", rb_enc_name(rb_enc_from_index(idx)));
    }
  }
  return frozen_bytes_into(str, args, buf);
}
#define frozen_utf8(str, args) frozen_utf8_into((str), (args), buf)

/* ---------------------------------------------------------------------------
 * Y::Doc
 * ------------------------------------------------------------------------- */

static void doc_free(void *p) { yrby_doc_free(p); }
static size_t doc_size(const void *p) { (void)p; return 64; }

static const rb_data_type_t doc_type = {
  .wrap_struct_name = "Y::Doc",
  .function = {.dfree = doc_free, .dsize = doc_size},
  .flags = RUBY_TYPED_FREE_IMMEDIATELY,
};

static void *doc_of(VALUE self) {
  void *doc = rb_check_typeddata(self, &doc_type);
  if (!doc) rb_raise(eError, "uninitialized Y::Doc");
  return doc;
}

static struct YrbyArgs on(VALUE self) {
  struct YrbyArgs args = {doc_of(self), NULL, 0, 0, 0};
  return args;
}

/*
 * Y::Doc.new(client_id = random). A singleton `new` with no allocator, like
 * the magnus build: no allocate/dup of an empty Doc, no initialize to re-run.
 * The client id converts as magnus's u64 does (TypeError, RangeError).
 */
static VALUE doc_s_new(int argc, VALUE *argv, VALUE klass) {
  VALUE client_id;
  rb_scan_args(argc, argv, "01", &client_id);
  struct YrbyArgs args = {NULL, NULL, 0, 0, 0};
  if (argc == 1) {
    if ((FIXNUM_P(client_id) && FIX2LONG(client_id) < 0) ||
        (RB_TYPE_P(client_id, T_BIGNUM) && !rb_big_sign(client_id)) ||
        (RB_FLOAT_TYPE_P(client_id) && RFLOAT_VALUE(client_id) <= -1.0))
      rb_raise(rb_eRangeError, "can't convert negative integer to unsigned");
    args.a = (int64_t)NUM2ULL(client_id);
    args.b = 1;
  }
  /* The wrapper first, so a raise here can't leak the Rust doc. */
  VALUE self = TypedData_Wrap_Struct(klass, &doc_type, NULL);
  struct YrbyResult r = yrby_doc_new(&args);
  check(r);
  RTYPEDDATA_DATA(self) = (void *)(uintptr_t)r.value;
  return self;
}

static VALUE doc_client_id(VALUE self) {
  struct YrbyArgs args = on(self);
  struct YrbyResult r = yrby_doc_client_id(&args);
  return ULL2NUM(r.value);
}

#define DOC_NOARG(name, fn, kind) \
  static VALUE name(VALUE self) { return finish(call(fn, on(self)), kind); }

DOC_NOARG(doc_encode_state_vector, yrby_doc_encode_state_vector, AS_BYTES)
DOC_NOARG(doc_pending, yrby_doc_pending, AS_BOOL)
DOC_NOARG(doc_compacted_state_update, yrby_doc_compacted_state_update, AS_BYTES)
DOC_NOARG(doc_sync_step1, yrby_doc_sync_step1, AS_BYTES)

#define DOC_BYTES(name, fn, kind)                           \
  static VALUE name(VALUE self, VALUE input) {              \
    struct YrbyArgs args = on(self);                        \
    INPUT_BUF;                                              \
    VALUE view = frozen_bytes(input, &args);                \
    VALUE out = finish(call(fn, args), kind);               \
    RB_GC_GUARD(view);                                      \
    return out;                                             \
  }

DOC_BYTES(doc_apply_update, yrby_doc_apply_update, AS_NIL)
DOC_BYTES(doc_update_ready, yrby_doc_update_ready, AS_BOOL)
DOC_BYTES(doc_update_advances, yrby_doc_update_advances, AS_BOOL)

#define DOC_NAME(name, fn)                                  \
  static VALUE name(VALUE self, VALUE root) {               \
    struct YrbyArgs args = on(self);                        \
    INPUT_BUF;                                              \
    VALUE view = frozen_utf8(root, &args);                  \
    VALUE out = finish(call(fn, args), AS_TEXT);               \
    RB_GC_GUARD(view);                                      \
    return out;                                             \
  }

DOC_NAME(doc_read_text, yrby_doc_read_text)
DOC_NAME(doc_read_xml, yrby_doc_read_xml)
DOC_NAME(doc_read_map, yrby_doc_read_map)
DOC_NAME(doc_read_array, yrby_doc_read_array)

static VALUE doc_encode_state_as_update(int argc, VALUE *argv, VALUE self) {
  INPUT_BUF;
  VALUE sv;
  rb_scan_args(argc, argv, "01", &sv);
  struct YrbyArgs args = on(self);
  VALUE view = Qnil;
  if (argc == 1) {
    view = frozen_bytes(sv, &args);
    args.b = 1;
  }
  VALUE out = finish(call(yrby_doc_encode_state_as_update, args), AS_BYTES);
  RB_GC_GUARD(view);
  return out;
}

static VALUE doc_root_names(VALUE self) {
  struct YrbyResult r = call(yrby_doc_root_names, on(self));
  check(r);
  VALUE names = rb_ary_new();
  for (size_t at = 0; at + 4 <= r.len;) {
    uint32_t n = (uint32_t)r.ptr[at] | (uint32_t)r.ptr[at + 1] << 8 |
                 (uint32_t)r.ptr[at + 2] << 16 | (uint32_t)r.ptr[at + 3] << 24;
    at += 4;
    rb_ary_push(names, rb_utf8_str_new((const char *)r.ptr + at, n));
    at += n;
  }
  yrby_free(r.ptr, r.len);
  rb_thread_check_ints();
  return names;
}

static VALUE doc_handle_sync_message(VALUE self, VALUE data) {
  INPUT_BUF;
  struct YrbyArgs args = on(self);
  VALUE view = frozen_bytes(data, &args);
  struct YrbyResult r = call(yrby_doc_handle_sync_message, args);
  RB_GC_GUARD(view);
  check(r);
  VALUE response = take_string(r, NULL);
  VALUE out = rb_ary_new_from_args(3, INT2FIX((r.value >> 8) & 0xff),
                                   INT2FIX(r.value & 0xff), response);
  rb_thread_check_ints();
  return out;
}

/* The merged unsent updates, or nil. An interrupt that arrives with them
 * puts them back before it propagates, as the magnus build does. */
static VALUE check_ints(VALUE unused) {
  (void)unused;
  rb_thread_check_ints();
  return Qnil;
}

static VALUE doc_take_unsent(VALUE self) {
  struct YrbyArgs args = on(self);
  struct YrbyResult r = call(yrby_doc_take_unsent, args);
  check(r);
  if (r.status == YRBY_STATUS_NIL) {
    rb_thread_check_ints();
    return Qnil;
  }
  args.ptr = r.ptr;
  args.len = r.len;
  VALUE taken = rb_str_new((const char *)r.ptr, (long)r.len);
  int state = 0;
  rb_protect(check_ints, Qnil, &state);
  if (state) {
    yrby_doc_keep_unsent(&args);
    yrby_free(r.ptr, r.len);
    rb_jump_tag(state);
  }
  yrby_free(r.ptr, r.len);
  return taken;
}

static VALUE doc_keep_unsent(VALUE self, VALUE update) {
  struct YrbyArgs args = on(self);
  VALUE view = frozen_bytes_into(update, &args, NULL);
  yrby_doc_keep_unsent(&args);
  RB_GC_GUARD(view);
  return Qnil;
}

/* ---------------------------------------------------------------------------
 * Y::Text
 * ------------------------------------------------------------------------- */

static void text_free(void *p) { yrby_text_free(p); }
static size_t text_size(const void *p) { (void)p; return 48; }

static const rb_data_type_t text_type = {
  .wrap_struct_name = "Y::Text",
  .function = {.dfree = text_free, .dsize = text_size},
  .flags = RUBY_TYPED_FREE_IMMEDIATELY,
};

/* Never NULL today (get_text wraps a finished handle); checked anyway, as
 * doc_of does, because a NULL here would be a segfault, not an error. */
static struct YrbyArgs on_text(VALUE self) {
  void *text = rb_check_typeddata(self, &text_type);
  if (!text) rb_raise(eError, "uninitialized Y::Text");
  struct YrbyArgs args = {text, NULL, 0, 0, 0};
  return args;
}

static VALUE wrap_text(VALUE handle) {
  return TypedData_Wrap_Struct(cText, &text_type, (void *)handle);
}

static VALUE doc_get_text(VALUE self, VALUE name) {
  INPUT_BUF;
  struct YrbyArgs args = on(self);
  VALUE view = frozen_utf8(name, &args);
  struct YrbyResult r = call(yrby_doc_get_text, args);
  RB_GC_GUARD(view);
  check(r);
  /* Wrap after the call, so no half-built Text is ever reachable, and free
   * the Rust handle if the allocation itself raises. */
  int state = 0;
  VALUE text = rb_protect(wrap_text, (VALUE)(uintptr_t)r.value, &state);
  if (state) {
    yrby_text_free((void *)(uintptr_t)r.value);
    rb_jump_tag(state);
  }
  rb_thread_check_ints();
  return text;
}

static VALUE text_to_s(VALUE self) { return finish(call(yrby_text_to_s, on_text(self)), AS_TEXT); }
static VALUE text_length(VALUE self) { return finish(call(yrby_text_length, on_text(self)), AS_INT); }
static VALUE text_empty(VALUE self) { return finish(call(yrby_text_is_empty, on_text(self)), AS_BOOL); }
static VALUE text_clear(VALUE self) { return finish(call(yrby_text_clear, on_text(self)), AS_NIL); }

static VALUE text_insert_at(VALUE self, int64_t index, VALUE chunk) {
  INPUT_BUF;
  struct YrbyArgs args = on_text(self);
  VALUE view = frozen_utf8(chunk, &args);
  args.a = index;
  finish(call(yrby_text_insert, args), AS_NIL);
  RB_GC_GUARD(view);
  return self;
}

static VALUE text_push(VALUE self, VALUE chunk) { return text_insert_at(self, -1, chunk); }

static VALUE text_insert(VALUE self, VALUE index, VALUE chunk) {
  return text_insert_at(self, NUM2LL(index), chunk);
}

static VALUE text_delete(VALUE self, VALUE index, VALUE length) {
  struct YrbyArgs args = on_text(self);
  args.a = NUM2LL(index);
  args.b = NUM2LL(length);
  return finish(call(yrby_text_delete, args), AS_NIL);
}

/* ---------------------------------------------------------------------------
 * Y module functions
 * ------------------------------------------------------------------------- */

#define CODEC(name, fn, kind)                               \
  static VALUE name(VALUE mod, VALUE input) {               \
    (void)mod;                                              \
    struct YrbyArgs args = {NULL, NULL, 0, 0, 0};           \
    INPUT_BUF;                                              \
    VALUE view = frozen_bytes(input, &args);                \
    VALUE out = finish(call(fn, args), kind);               \
    RB_GC_GUARD(view);                                      \
    return out;                                             \
  }

CODEC(y_message_kind, yrby_message_kind, AS_INT)
CODEC(y_update_from_message, yrby_update_from_message, AS_BYTES)

/* Cheap enough to keep the GVL, as the magnus build does. */
static VALUE y_wrap_update(VALUE mod, VALUE update) {
  (void)mod;
  struct YrbyArgs args = {NULL, NULL, 0, 0, 0};
  VALUE view = frozen_bytes_into(update, &args, NULL);
  struct YrbyResult r = yrby_wrap_update(&args);
  RB_GC_GUARD(view);
  check(r);
  return take_string(r, NULL);
}

void Init_yrby_c(void) {
  mY = rb_define_module("Y");
  eError = rb_define_class_under(mY, "Error", rb_eStandardError);

  cDoc = rb_define_class_under(mY, "Doc", rb_cObject);
  rb_undef_alloc_func(cDoc);
  rb_define_singleton_method(cDoc, "new", doc_s_new, -1);
  rb_define_method(cDoc, "client_id", doc_client_id, 0);
  rb_define_method(cDoc, "encode_state_vector", doc_encode_state_vector, 0);
  rb_define_method(cDoc, "encode_state_as_update", doc_encode_state_as_update, -1);
  rb_define_method(cDoc, "apply_update", doc_apply_update, 1);
  rb_define_method(cDoc, "root_names", doc_root_names, 0);
  rb_define_method(cDoc, "read_text", doc_read_text, 1);
  rb_define_method(cDoc, "read_xml", doc_read_xml, 1);
  rb_define_method(cDoc, "read_map", doc_read_map, 1);
  rb_define_method(cDoc, "read_array", doc_read_array, 1);
  rb_define_method(cDoc, "pending?", doc_pending, 0);
  rb_define_method(cDoc, "compacted_state_update", doc_compacted_state_update, 0);
  rb_define_method(cDoc, "update_ready?", doc_update_ready, 1);
  rb_define_method(cDoc, "update_advances?", doc_update_advances, 1);
  rb_define_method(cDoc, "sync_step1", doc_sync_step1, 0);
  rb_define_method(cDoc, "handle_sync_message", doc_handle_sync_message, 1);
  rb_define_method(cDoc, "get_text", doc_get_text, 1);
  rb_define_private_method(cDoc, "native_take_unsent", doc_take_unsent, 0);
  rb_define_private_method(cDoc, "native_keep_unsent", doc_keep_unsent, 1);

  cText = rb_define_class_under(mY, "Text", rb_cObject);
  rb_undef_alloc_func(cText);
  rb_define_method(cText, "to_s", text_to_s, 0);
  rb_define_method(cText, "to_str", text_to_s, 0);
  rb_define_method(cText, "push", text_push, 1);
  rb_define_method(cText, "<<", text_push, 1);
  rb_define_method(cText, "insert", text_insert, 2);
  rb_define_method(cText, "delete", text_delete, 2);
  rb_define_method(cText, "clear", text_clear, 0);
  rb_define_method(cText, "length", text_length, 0);
  rb_define_method(cText, "size", text_length, 0);
  rb_define_method(cText, "empty?", text_empty, 0);

  rb_define_module_function(mY, "wrap_update", y_wrap_update, 1);
  rb_define_module_function(mY, "message_kind", y_message_kind, 1);
  rb_define_module_function(mY, "update_from_message", y_update_from_message, 1);

  /* Not ported in the spike; defined so lib/y/rendering.rb loads. */
  rb_define_class_under(mY, "NativeLexical", rb_cObject);
  rb_define_class_under(mY, "NativeProseMirror", rb_cObject);

  rb_define_const(mY, "MSG_SYNC", INT2FIX(0));
  rb_define_const(mY, "MSG_AWARENESS", INT2FIX(1));
  rb_define_const(mY, "MSG_SYNC_STEP1", INT2FIX(0));
  rb_define_const(mY, "MSG_SYNC_STEP2", INT2FIX(1));
  rb_define_const(mY, "MSG_SYNC_UPDATE", INT2FIX(2));
}
