/* Console bridge only. mirage-solo5's own main.c is the entry point here: it
   installs the heap and the runtime hooks, then calls caml_startup. */
#include <solo5.h>
#define CAML_NAME_SPACE
#include <caml/mlvalues.h>
#include <caml/memory.h>

CAMLprim value cardano_console_write(value s)
{
    solo5_console_write(String_val(s), caml_string_length(s));
    return Val_unit;
}
