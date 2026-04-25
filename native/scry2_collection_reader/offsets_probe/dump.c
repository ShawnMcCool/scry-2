/*
 * Mono struct offset dumper for Unity-Technologies/mono `unity-2022.3-mbe`.
 *
 * Compile with `-mms-bitfields` to match MSVC's rule that bitfields of
 * different underlying types start new storage units (GCC's default
 * coalesces regardless of type).
 *
 * Struct bodies are verbatim from:
 *   mono/metadata/class-private-definition.h
 *   mono/metadata/class-internals.h
 *   mono/metadata/metadata-internals.h
 *   mono/metadata/domain-internals.h
 *   mono/metadata/property-bag.h
 *   mono/metadata/object.h
 *   mono/metadata/object-internals.h
 *   mono/eglib/glib.h            (GSList)
 *   mono/utils/mono-publib.h     (mono_byte, MonoBoolean)
 *
 * Supporting typedefs are reproduced minimally; every one that affects
 * layout (size/alignment) has a static_assert guarding its width.
 *
 * `MonoImage` and `MonoAssembly` are reproduced **only up to** the
 * fields the walker reads. Truncating their tail does not affect the
 * `offsetof` of any reproduced field — those are computed solely from
 * the prefix.
 */

#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <stddef.h>

/* ---- glib-style typedefs (size-critical; widths asserted below) ---- */
typedef unsigned char      guint8;
typedef unsigned short     guint16;
typedef unsigned int       guint;
typedef unsigned int       guint32;
typedef int                gint32;
typedef unsigned long long guint64;
typedef int                gboolean;
typedef void              *gpointer;

/* mono/utils/mono-publib.h — mono_byte / MonoBoolean. */
typedef uint8_t  mono_byte;
typedef mono_byte MonoBoolean;

_Static_assert(sizeof(guint8)  == 1, "guint8 must be 1 byte");
_Static_assert(sizeof(guint16) == 2, "guint16 must be 2 bytes");
_Static_assert(sizeof(guint32) == 4, "guint32 must be 4 bytes");
_Static_assert(sizeof(guint64) == 8, "guint64 must be 8 bytes");
_Static_assert(sizeof(guint)   == 4, "guint must be 4 bytes");
_Static_assert(sizeof(gpointer) == 8, "gpointer must be 8 bytes on x86-64");
_Static_assert(sizeof(mono_byte) == 1, "mono_byte must be 1 byte");
_Static_assert(sizeof(MonoBoolean) == 1, "MonoBoolean must be 1 byte");

/* ---- Forward declarations ---- */
typedef struct _MonoClass             MonoClass;
typedef struct _MonoClassDef          MonoClassDef;
typedef struct _MonoMethod            MonoMethod;
typedef struct _MonoImage             MonoImage;
typedef struct _MonoImageStorage      MonoImageStorage;
typedef struct _MonoArrayType         MonoArrayType;
typedef struct _MonoMethodSignature   MonoMethodSignature;
typedef struct _MonoGenericParam      MonoGenericParam;
typedef struct _MonoGenericClass      MonoGenericClass;
typedef struct _MonoGenericContainer  MonoGenericContainer;
typedef struct _MonoType              MonoType;
typedef struct _MonoClassField        MonoClassField;
typedef struct _MonoDomain            MonoDomain;
typedef struct _MonoThreadsSync       MonoThreadsSync;
typedef struct _MonoPropertyBagItem   MonoPropertyBagItem;
typedef struct _MonoClassRuntimeInfo  MonoClassRuntimeInfo;
typedef struct _MonoArrayBounds       MonoArrayBounds;
typedef struct _MonoAssembly          MonoAssembly;
typedef struct _MonoAssemblyName      MonoAssemblyName;

/* MonoGCDescriptor is a pointer-sized typedef in the bdwgc runtime. */
typedef gpointer MonoGCDescriptor;

/* MonoTypeEnum — opaque enum, width = int (4 bytes). */
typedef int MonoTypeEnum;

/* Runtime generic context — typedef'd to gpointer in class-internals.h. */
typedef gpointer MonoRuntimeGenericContext;

/* mono_array_size_t — uintptr_t on 64-bit Windows per Unity MBE. */
typedef uintptr_t mono_array_size_t;
typedef uint64_t mono_64bitaligned_t;

/* ---- MonoPropertyBagItem / MonoPropertyBag (property-bag.h) ---- */
struct _MonoPropertyBagItem {
    MonoPropertyBagItem *next;
    int tag;
};

typedef struct {
    MonoPropertyBagItem *head;
} MonoPropertyBag;

/* ---- MonoType (metadata-internals.h) ---- */
struct _MonoType {
    union {
        MonoClass *klass;
        MonoType *type;
        MonoArrayType *array;
        MonoMethodSignature *method;
        MonoGenericParam *generic_param;
        MonoGenericClass *generic_class;
    } data;
    unsigned int attrs     : 16;
    MonoTypeEnum type      : 8;
    unsigned int has_cmods : 1;
    unsigned int byref     : 1;
    unsigned int pinned    : 1;
};

/* ---- MonoClassField (class-internals.h) ---- */
struct _MonoClassField {
    MonoType  *type;
    const char *name;
    MonoClass *parent;
    int        offset;
};

/* ---- _MonoClassSizes union (class-internals.h) ---- */
union _MonoClassSizes {
    int class_size;
    int element_size;
    int generic_param_token;
};

/* ---- _MonoClass (class-private-definition.h — verbatim) ---- */
struct _MonoClass {
    MonoClass *element_class;
    MonoClass *cast_class;

    MonoClass **supertypes;
    guint16     idepth;
    guint8      rank;
    guint8      class_kind;
    int         instance_size;

    guint inited                     : 1;
    guint size_inited                : 1;
    guint valuetype                  : 1;
    guint enumtype                   : 1;
    guint blittable                  : 1;
    guint unicode                    : 1;
    guint wastypebuilder             : 1;
    guint is_array_special_interface : 1;
    guint is_byreflike               : 1;

    guint8 min_align;

    guint packing_size    : 4;
    guint ghcimpl         : 1;
    guint has_finalize    : 1;
    /* DISABLE_REMOTING is off in MBE builds */
    guint marshalbyref    : 1;
    guint contextbound    : 1;

    guint delegate                  : 1;
    guint gc_descr_inited           : 1;
    guint has_cctor                 : 1;
    guint has_references            : 1;
    guint has_static_refs           : 1;
    guint no_special_static_fields  : 1;
    guint is_com_object             : 1;
    guint nested_classes_inited     : 1;

    guint interfaces_inited      : 1;
    guint simd_type              : 1;
    guint has_finalize_inited    : 1;
    guint fields_inited          : 1;
    guint has_failure            : 1;
    guint has_weak_fields        : 1;
    guint has_dim_conflicts      : 1;

    MonoClass  *parent;
    MonoClass  *nested_in;

    MonoImage  *image;
    const char *name;
    const char *name_space;

    guint32 type_token;
    int     vtable_size;

    guint16 interface_count;
    guint32 interface_id;
    guint32 max_interface_id;

    guint16     interface_offsets_count;
    MonoClass **interfaces_packed;
    guint16    *interface_offsets_packed;
    guint8     *interface_bitmap;

    MonoClass **interfaces;

    union _MonoClassSizes sizes;

    MonoClassField *fields;

    MonoMethod **methods;

    MonoType this_arg;
    MonoType _byval_arg;

    MonoGCDescriptor gc_descr;

    MonoClassRuntimeInfo *runtime_info;

    MonoMethod **vtable;

    MonoPropertyBag infrequent_data;

    void *unity_user_data;
};

/* ---- MonoVTable (class-internals.h) ---- */
#define MONO_VTABLE_AVAILABLE_GC_BITS 4

struct _MonoVTable {
    MonoClass *klass;
    MonoGCDescriptor gc_descr;
    MonoDomain *domain;
    gpointer type;
    guint8 *interface_bitmap;
    guint32 max_interface_id;
    guint8 rank;
    guint8 initialized;
    guint8 flags;
    guint remote             : 1;
    guint init_failed        : 1;
    guint has_static_fields  : 1;
    guint gc_bits            : MONO_VTABLE_AVAILABLE_GC_BITS;

    guint32 imt_collisions_bitmap;
    MonoRuntimeGenericContext *runtime_generic_context;
    gpointer *interp_vtable;
    gpointer vtable[1]; /* flex */
};

/* ---- MonoObject (object.h) ---- */
struct _MonoObject {
    struct _MonoVTable *vtable;
    MonoThreadsSync *synchronisation;
};
typedef struct _MonoObject MonoObject;

/* ---- MonoArray (object-internals.h) ---- */
struct _MonoArray {
    MonoObject obj;
    MonoArrayBounds *bounds;
    mono_array_size_t max_length;
    mono_64bitaligned_t vector[1];
};

/* ---- MonoClassDef (class-private-definition.h) ---- */
struct _MonoClassDef {
    struct _MonoClass klass;
    guint32 flags;
    guint32 first_method_idx;
    guint32 first_field_idx;
    guint32 method_count, field_count;
    MonoClass *next_class_cache;
};

/* ---- GSList (mono/eglib/glib.h) ----
 *
 * Singly linked list node. The walker reads `data` (pointer to a
 * MonoAssembly) and `next` (pointer to the next GSList node) to
 * iterate `MonoDomain.domain_assemblies`.
 */
typedef struct _GSList GSList;
struct _GSList {
    gpointer data;
    GSList *next;
};

/* ---- MonoAssemblyName (metadata-internals.h) ----
 *
 * Verbatim from `metadata-internals.h`. ENABLE_NETCORE is OFF in MBE
 * builds, so the version members are `uint16_t` (not `int32_t`).
 */
#define MONO_PUBLIC_KEY_TOKEN_LENGTH 17

struct _MonoAssemblyName {
    const char *name;
    const char *culture;
    const char *hash_value;
    const mono_byte *public_key;
    mono_byte public_key_token[MONO_PUBLIC_KEY_TOKEN_LENGTH];
    uint32_t hash_alg;
    uint32_t hash_len;
    uint32_t flags;
    uint16_t major, minor, build, revision, arch;
    MonoBoolean without_version;
    MonoBoolean without_culture;
    MonoBoolean without_public_key_token;
};

/* ---- MonoAssemblyContext (metadata-internals.h) ---- */
typedef enum {
    MONO_ASMCTX_DEFAULT = 0,
    MONO_ASMCTX_REFONLY = 1,
    MONO_ASMCTX_LOADFROM = 2,
    MONO_ASMCTX_INDIVIDUAL = 3,
    MONO_ASMCTX_INTERNAL = 4,
} MonoAssemblyContextKind;

typedef struct {
    MonoAssemblyContextKind kind;
} MonoAssemblyContext;

/* ---- MonoAssembly (metadata-internals.h) ----
 *
 * Reproduced **only up to the `image` field** the walker reads.
 * Truncating after `image` does not affect any reproduced field's
 * `offsetof` — it is computed solely from the prefix.
 */
struct _MonoAssembly {
    gint32 ref_count;
    char *basedir;
    MonoAssemblyName aname;
    MonoImage *image;
    /* Trailing fields elided — not consumed by the walker. */
};

/* ---- MonoImage (metadata-internals.h) ----
 *
 * Reproduced **only up to the `assembly_name` field** the walker
 * may read. Truncating after `assembly_name` does not affect any
 * reproduced field's `offsetof`.
 *
 * The 12 single-bit `guint8` flags pack into 2 bytes under MSVC
 * bitfield rules (`-mms-bitfields`): same-underlying-type bitfields
 * coalesce into the same storage unit, with each `guint8` providing
 * up to 8 bits.
 */
struct _MonoImage {
    int   ref_count;
    MonoImageStorage *storage;
    char *raw_data;
    guint32 raw_data_len;

    guint8 dynamic               : 1;
    guint8 ref_only              : 1;
    guint8 uncompressed_metadata : 1;
    guint8 metadata_only         : 1;
    guint8 load_from_context     : 1;
    guint8 checked_module_cctor  : 1;
    guint8 has_module_cctor      : 1;
    guint8 idx_string_wide       : 1;
    guint8 idx_guid_wide         : 1;
    guint8 idx_blob_wide         : 1;
    guint8 core_clr_platform_code: 1;
    guint8 minimal_delta         : 1;

    char *name;
    char *filename;
    const char *assembly_name;
    /* Trailing fields elided — not consumed by the walker. */
};

/* ===================================================================
 * Dump
 * =================================================================== */

#define P_SIZE(T)        printf("%-32s %zu\n", "sizeof(" #T ")", sizeof(T))
#define P_OFFSET(T, F)   printf("%-32s %zu (0x%zx)\n", #T "." #F, \
                                offsetof(T, F), offsetof(T, F))

int main(void) {
    puts("=== sizes ===");
    P_SIZE(MonoType);
    P_SIZE(MonoClassField);
    P_SIZE(struct _MonoClass);
    P_SIZE(struct _MonoVTable);
    P_SIZE(MonoObject);
    P_SIZE(struct _MonoArray);
    P_SIZE(MonoPropertyBag);

    puts("\n=== MonoClass ===");
    P_OFFSET(struct _MonoClass, element_class);
    P_OFFSET(struct _MonoClass, cast_class);
    P_OFFSET(struct _MonoClass, supertypes);
    P_OFFSET(struct _MonoClass, idepth);
    P_OFFSET(struct _MonoClass, rank);
    P_OFFSET(struct _MonoClass, class_kind);
    P_OFFSET(struct _MonoClass, instance_size);
    P_OFFSET(struct _MonoClass, min_align);
    P_OFFSET(struct _MonoClass, parent);
    P_OFFSET(struct _MonoClass, nested_in);
    P_OFFSET(struct _MonoClass, image);
    P_OFFSET(struct _MonoClass, name);
    P_OFFSET(struct _MonoClass, name_space);
    P_OFFSET(struct _MonoClass, type_token);
    P_OFFSET(struct _MonoClass, vtable_size);
    P_OFFSET(struct _MonoClass, interface_count);
    P_OFFSET(struct _MonoClass, interface_id);
    P_OFFSET(struct _MonoClass, max_interface_id);
    P_OFFSET(struct _MonoClass, interface_offsets_count);
    P_OFFSET(struct _MonoClass, interfaces_packed);
    P_OFFSET(struct _MonoClass, interface_offsets_packed);
    P_OFFSET(struct _MonoClass, interface_bitmap);
    P_OFFSET(struct _MonoClass, interfaces);
    P_OFFSET(struct _MonoClass, sizes);
    P_OFFSET(struct _MonoClass, fields);
    P_OFFSET(struct _MonoClass, methods);
    P_OFFSET(struct _MonoClass, this_arg);
    P_OFFSET(struct _MonoClass, _byval_arg);
    P_OFFSET(struct _MonoClass, gc_descr);
    P_OFFSET(struct _MonoClass, runtime_info);
    P_OFFSET(struct _MonoClass, vtable);
    P_OFFSET(struct _MonoClass, infrequent_data);
    P_OFFSET(struct _MonoClass, unity_user_data);

    puts("\n=== MonoClassField ===");
    P_OFFSET(MonoClassField, type);
    P_OFFSET(MonoClassField, name);
    P_OFFSET(MonoClassField, parent);
    P_OFFSET(MonoClassField, offset);

    puts("\n=== MonoVTable ===");
    P_OFFSET(struct _MonoVTable, klass);
    P_OFFSET(struct _MonoVTable, gc_descr);
    P_OFFSET(struct _MonoVTable, domain);
    P_OFFSET(struct _MonoVTable, type);
    P_OFFSET(struct _MonoVTable, interface_bitmap);
    P_OFFSET(struct _MonoVTable, max_interface_id);
    P_OFFSET(struct _MonoVTable, rank);
    P_OFFSET(struct _MonoVTable, initialized);
    P_OFFSET(struct _MonoVTable, flags);
    P_OFFSET(struct _MonoVTable, imt_collisions_bitmap);
    P_OFFSET(struct _MonoVTable, runtime_generic_context);
    P_OFFSET(struct _MonoVTable, interp_vtable);
    P_OFFSET(struct _MonoVTable, vtable);

    puts("\n=== MonoObject ===");
    P_OFFSET(MonoObject, vtable);
    P_OFFSET(MonoObject, synchronisation);

    puts("\n=== MonoArray ===");
    P_OFFSET(struct _MonoArray, obj);
    P_OFFSET(struct _MonoArray, bounds);
    P_OFFSET(struct _MonoArray, max_length);
    P_OFFSET(struct _MonoArray, vector);

    puts("\n=== MonoClassDef ===");
    P_SIZE(struct _MonoClassDef);
    P_OFFSET(struct _MonoClassDef, klass);
    P_OFFSET(struct _MonoClassDef, flags);
    P_OFFSET(struct _MonoClassDef, first_method_idx);
    P_OFFSET(struct _MonoClassDef, first_field_idx);
    P_OFFSET(struct _MonoClassDef, method_count);
    P_OFFSET(struct _MonoClassDef, field_count);
    P_OFFSET(struct _MonoClassDef, next_class_cache);

    puts("\n=== GSList ===");
    P_SIZE(GSList);
    P_OFFSET(GSList, data);
    P_OFFSET(GSList, next);

    puts("\n=== MonoAssemblyName ===");
    P_SIZE(MonoAssemblyName);
    P_OFFSET(MonoAssemblyName, name);
    P_OFFSET(MonoAssemblyName, culture);
    P_OFFSET(MonoAssemblyName, hash_value);
    P_OFFSET(MonoAssemblyName, public_key);
    P_OFFSET(MonoAssemblyName, public_key_token);
    P_OFFSET(MonoAssemblyName, hash_alg);
    P_OFFSET(MonoAssemblyName, hash_len);
    P_OFFSET(MonoAssemblyName, flags);
    P_OFFSET(MonoAssemblyName, major);

    puts("\n=== MonoAssembly (truncated to .image) ===");
    P_OFFSET(struct _MonoAssembly, ref_count);
    P_OFFSET(struct _MonoAssembly, basedir);
    P_OFFSET(struct _MonoAssembly, aname);
    P_OFFSET(struct _MonoAssembly, image);

    puts("\n=== MonoImage (truncated to .assembly_name) ===");
    P_OFFSET(struct _MonoImage, ref_count);
    P_OFFSET(struct _MonoImage, storage);
    P_OFFSET(struct _MonoImage, raw_data);
    P_OFFSET(struct _MonoImage, raw_data_len);
    P_OFFSET(struct _MonoImage, name);
    P_OFFSET(struct _MonoImage, filename);
    P_OFFSET(struct _MonoImage, assembly_name);

    return 0;
}
