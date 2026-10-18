# The compiled format

riverrun compiles a story into two files: the **graph** (`RIVERRUN`), which holds
sections, steps, choices, conditions, effects, facts and tags, and the **string
table** (`RIVERTXT`), which holds every line's words by line id. A translation is
another string table for the same graph. A snapshot of facts (`RRFACTS`) is the
third format, described last.

This document is the specification. A runtime in another language reads these
files from it alone. `src/story/format.zig` is the same layout in Zig.

## Conventions

- Every integer is little-endian. Records are laid out as C structs with natural
  alignment; every record's size is a multiple of its alignment, and the sizes below
  include their padding. Padding bytes are zero.
- A **Str** is `{ offset: u32, len: u32 }`, a span of the file's byte table (`names`
  in the graph, `bytes` in the string table). It lies inside the table and its ends
  fall on UTF-8 character boundaries; the table as a whole is valid UTF-8.
- A **Range** is `{ start: u32, len: u32 }`, a run of `len` records of another table
  from record `start`.
- `none` is `0xFFFFFFFF` in a 32-bit index and `0xFFFF` in a 16-bit one.
- Names are qualified by their module: `module.name`, the root module's bare.
- The hash is XxHash64 with seed 0. A **line id** is the XxHash64 (seed 0) of the
  line's `# id` text; it is never zero.

## Layout of a file

Both the graph and the string table are:

```
Header      32 bytes
Directory   Header.tables × 16 bytes
Tables      each starting at a multiple of 8
```

| Header field | type | |
|---|---|---|
| magic | [8]u8 | `RIVERRUN` or `RIVERTXT` |
| major | u16 | 1 |
| minor | u16 | 0 |
| flags | u32 | 0 |
| hash | u64 | XxHash64 of the whole file with these 8 bytes taken as zero |
| length | u32 | the file's length |
| tables | u32 | directory entries |

| Directory entry | type | |
|---|---|---|
| offset | u32 | where the table starts, a multiple of 8, after the directory |
| count | u32 | records |
| stride | u32 | bytes per record: at least the record's size in this version |
| reserved | u32 | 0 |

Directory entries are in the fixed order of the tables below.

### Versions

- A reader refuses another **major** version.
- A newer **minor** version may append tables to the directory and fields to the
  end of a record. A reader skips tables past those it knows, and reads each record
  at `offset + i × stride`, ignoring bytes past the fields it knows.
- A minor version never changes the meaning of an existing field, table or term.

## The graph: `RIVERRUN`

| # | table | record | size |
|---|---|---|---|
| 0 | meta | Meta | 8 |
| 1 | names | u8 | 1 |
| 2 | scopes | Str | 8 |
| 3 | enums | Range into items | 8 |
| 4 | items | Str | 8 |
| 5 | facts | Fact | 16 |
| 6 | cast | Cast | 40 |
| 7 | externs | Extern | 24 |
| 8 | params | Param | 4 |
| 9 | literals | Str | 8 |
| 10 | ints | i64 | 8 |
| 11 | terms | u32 (Term) | 4 |
| 12 | sections | Section | 44 |
| 13 | candidates | Candidate | 36 |
| 14 | nodes | Node | 32 |
| 15 | choices | Choice | 28 |
| 16 | texts | Text | 16 |
| 17 | slots | Slot | 12 |
| 18 | effects | Effect | 20 |
| 19 | tags | Tag | 16 |
| 20 | tag_values | TagValue | 12 |
| 21 | kinds | Str | 8 |
| 22 | things | Thing | 12 |

### Declarations

**Meta** (exactly one record): `seed: u16`, `turn: u16` (fact ids), `reserved_scope:
u8`, 3 bytes padding. The reserved scope is named `story`; it holds the executor's
own state. `seed` is the seed for shuffles; `turn` counts the turns that pools'
memory is stamped with. Both are int facts of role `state` in the reserved scope.

**Scopes**: names a host stores facts under (`life`, `player`, `world`), at most 32.

**Enums** and **items**: an enumeration is a range of 1 to 256 items, each a name.
A `one of` fact holds one item or none; a `set of` fact holds any of them.

**Fact**:

| field | type | |
|---|---|---|
| name | Str | qualified; facts of the reserved scope are `visits:<what>` or `state:<what>` |
| enumeration | u16 | for `one_of` and `set_of`, the enumeration; for `ref`, its kind; else `none` |
| scope | u8 | |
| kind | u8 | 0 boolean, 1 int, 2 one_of, 3 set_of, 4 text, 5 ref |
| role | u8 | 0 story, 1 game (written by the game, never the story), 2 visits, 3 state, 4 clock (the game's, an int only ever advanced) |
| padding | 3 bytes | |

At most 4,096 facts. Visit counts are int facts of role `visits`, one per section,
per choice (named by its line id text) and per labelled gather. Alternatives' state
and a candidate's last-seen turn are int facts of role `state`. They are facts like
any other, so they are saved and restored with their scope.

Initial values: false, 0, none, the empty set, the empty text, no thing (0).

**Kinds** name the kinds of the host's things a `ref` holds (`person`, `item_kind`), at
most 65,534. **Thing**: `id: Str` (its stable text id, `wolf_pelt`), `kind: u16`, 2 bytes
padding: one of the host's things a story names. A host resolves every thing to its own
64-bit handle once, at load; a `ref` value is that handle, and 0 holds no thing.

**Cast**: `display: u64` (line id of the name shown), `relation: u64` (line id of who
they are, or 0), `name: Str` (empty for an extra), `tags: Range`, `extra: u8` (1 for
someone who speaks once and has no name), 7 bytes padding. At most 65,534.

**Extern**: a host function. `name: Str`, `params: Range` into params, `enumeration:
u16`, `returns: u8` (a kind, or `0xFF` for nothing), `action: u8`, 4 bytes padding.
A **query** (`action` 0) is pure, returns a value, and may be asked at any time. An
**action** (`action` 1) is performed by the host when the story reaches it; it may
return an outcome, which the host writes into the effect's result fact.

**Param**: `enumeration: u16` (or a `ref`'s kind), `kind: u8`, 1 byte padding.

### Terms: conditions and values

A condition, a value or a list of arguments is a range of **terms**, in postfix,
evaluated on a stack of at most 64 values. A term is a u32: the op in its low byte,
its argument in the high 24 bits.

| op | | argument | stack |
|---|---|---|---|
| 0 fact | push a fact's value | fact id | → v |
| 1 int | push an integer | index into ints | → int |
| 2 item | push an item | enumeration << 8 \| item | → one_of |
| 3 text | push a text | index into literals | → text |
| 4 true, 5 false | | 0 | → bool |
| 6 eq, 7 ne | same kind and enumeration | 0 | a b → bool |
| 8 has, 9 hasnt | a set holds an item of its enumeration | 0 | set item → bool |
| 10 and, 11 or | | 0 | bool bool → bool |
| 12 not | | 0 | bool → bool |
| 13 query | call a query on its arguments | extern id | args → its kind |
| 14 lt, 15 le, 16 gt, 17 ge | ints compared | 0 | int int → bool |
| 18 thing | push a thing's handle | index into things | → ref of its kind |

`eq` and `ne` compare refs of one kind by handle; a ref that holds no thing equals
nothing, as a `one of` that holds no value does.

`seen(name)` is the visits fact of what it names; as a condition, `visits 0 gt`.
There are no jumps: `and` and `or` evaluate both sides, which is sound because
queries are pure. A condition leaves one bool; a value one value; a `set` effect one
value of its fact's kind and enumeration; a call's arguments exactly its parameters,
in order.

### Sections and pools

**Section**:

| field | type | |
|---|---|---|
| name | Str | qualified |
| kind_name | Str | the host's kind, for `other` |
| tags | Range | |
| candidates | Range | a pool's candidates, else empty |
| entry | u32 | first node; `none` only for a pool |
| pick | u16 | a pool gives this many candidates at once, at least 1 |
| visits | u16 | int fact |
| kind | u8 | 0 scene, 1 pool, 2 other |
| padding | 3 bytes | |

**Candidate**: `name: Str`, `when: Range` (a condition; empty matches always), `tags:
Range`, `entry: u32`, `specificity: u16`, `visits: u16`, `seen: u16`, 2 bytes padding.
`specificity` counts the condition's criteria: each comparison, fact or query
counts one, `and` adds, `or` takes the lesser. Of the candidates that match, the most
specific win, then the least recently seen (`seen` holds the turn each was last given).

### Nodes: the steps

**Node**: `tags: Range`, `a, b, c, d: u32`, `next: u32`, `speaker: u16`, `kind: u8`,
1 byte padding. `next` is the step after; `none` ends the flow. Fields a kind does
not use are zero (`speaker` and `next` are `none`).

| kind | a | b | c | d | next | |
|---|---|---|---|---|---|---|
| 0 line | text | effects.start | effects.len | 0 | yes | `speaker` is a cast index or `none` for narration |
| 1 choices | choices.start | choices.len (1 to 32) | 0 | 0 | yes | `next` is where the flow goes when no choice is open |
| 2 branch | cond.start | cond.len | then | otherwise | `none` | `then` and `otherwise` are nodes or `none` |
| 3 gather | visits fact or `0xFFFF` | 0 | 0 | 0 | yes | |
| 4 effects | effects.start | effects.len | 0 | 0 | yes | |
| 5 jump | section | 0 | 0 | 0 | `none` | |
| 6 call | section | 0 | 0 | 0 | yes | `next` is where the section returns to |
| 7 ret | 0 | 0 | 0 | 0 | `none` | back to the caller |
| 8 end | 0 | 0 | 0 | 0 | `none` | the story ends |

A line's effects happen when the line is delivered: a host that does not deliver a
line does not apply them. An effects step's happen when it is reached.

**Choice**: `cond: Range` (empty is always open), `tags: Range`, `text: u32`, `target:
u32` (node), `visits: u16` (int fact), `sticky: u8` (1 stays offered; 0 is offered
until taken once), 1 byte padding. A choice whose condition fails is still offered,
marked closed.

### Texts

**Text**: `line: u64` (its line id in the string table), `slots: Range` (at most 32).

**Slot**: `expr: Range`, `state: u16`, `kind: u8`, `arity: u8`.

| kind | expr | arity | state |
|---|---|---|---|
| 0 value | a value | 0 | `none` |
| 1 choose | a condition | 2 | `none` |
| 2 sequence, 3 cycle, 4 once, 5 shuffle | empty | 1 to 32 | int fact |

The words are the string table's: a slot is only what fills a place in them.

### Effects

**Effect**: `expr: Range`, `fact: u16`, `item: u16`, `action: u16`, `result: u16`,
`kind: u8`, 3 bytes padding.

| kind | uses | unused |
|---|---|---|
| 0 set | fact, expr (its value) | item 0, action and result `none` |
| 1 add, 2 remove | fact (a set), item | expr empty, action and result `none` |
| 3 call | action (an action), expr (its arguments), result (a fact or `none`) | fact `none`, item 0 |
| 4 change | fact (an int), expr (an int: the amount, negative for `-=`) | item 0, action and result `none` |

riverrun never applies an effect: a step emits it for the host. A `change` moves an int by its
amount; a host that applies it refuses a result past what an i64 holds. A call with a result
is a check with an outcome: the host writes the action's result into `result` before
the story's next step, and the story branches on it.

### Tags

**Tag**: `key: Str`, `values: Range` into tag_values. **TagValue**: `text: Str`,
`section: u32`, the section the value names when the host's tag schema types it so,
else `none`. riverrun carries tags and never reads them.

## The string table: `RIVERTXT`

| # | table | record | size |
|---|---|---|---|
| 0 | meta | Meta | 16 |
| 1 | bytes | u8 | 1 |
| 2 | ids | u64 | 8 |
| 3 | entries | Entry | 16 |

**Meta** (one record): `story: u64`, the hash of the graph the table was made with,
and `locale: Str`, a BCP 47 tag. A translation may carry an earlier graph's hash:
what decides whether it serves a graph is the check below, not the hash.

**ids** are line ids in strictly ascending order; **entries** are parallel to them:
`id_text: Str` (the `# id` text, for tools and voice scripts) and `template: Str`.

### Templates

```
template = { literal | escape | slot }
escape   = "\" ( "{" | "}" | "|" | "\" )
slot     = "{" index [ ":" template { "|" template } ] "}"
```

`index` is one or two decimal digits below 32: the slot of the text. `{0}` writes a
value slot's value. `{1:a|b}` writes the branch its slot chooses: a `choose` has two
branches (the condition holds, it does not); alternatives have their arity. A bare
`|` outside a slot's branches is literal. Branches nest at most 8 deep.

A string table **serves** a graph when every text's line id and every cast member's
display and relation are in it, and every template uses its text's slots as the
graph declares them: a value slot without branches, any other with exactly its
arity. A translation may move slots, leave one out, or use one twice.

## Snapshots: `RRFACTS`

A scope's facts, for a save. Every value is written by name, so a snapshot restores
under another version of the story: facts are matched by name, items by name within
their fact, and what no longer fits is reported, never guessed.

```
magic    "RRFACTS\0"
version  u16 (1), flags u16 (0)
story    u64     the hash of the graph it was taken under
scope    str
count    u32     at most 4,096
facts    count × { name str, kind u8, value }

str      u16 length, then that many bytes of UTF-8
value    boolean u8 (0 or 1) · int i64 · one_of str (empty: none)
         · set_of u16 count (at most 256), then count × str · text str (at most 1,024 bytes)
         · ref u8 form, then form 0: u64 handle · form 1: str id
```

Names are at most 256 bytes. A restore applies nothing unless every byte is accepted.

A `ref` holding a thing the story names is saved by its text id (form 1) and restored
to whatever handle the host gives that id then, so a host may number its handles anew
each run. Any other ref (a thing the host bound at run time, with no text id in the
story) is saved as the host's handle (form 0), which must then be that thing's lasting
id. Ids are the stable names; handles are only as lasting as the host makes them.

## What a reader validates

Before it trusts a graph, a reader checks:

1. The header: magic, major version, length, at least the tables it knows, and the
   hash (a host that verified the bytes otherwise may skip it).
2. The directory: every table inside the file, after the directory, aligned to 8,
   with a stride at least its record's size.
3. Names: the names table is UTF-8, and every Str lies in it on character boundaries.
4. Bounds: at most 32 scopes, 4,096 facts, 256 items an enumeration, 32 choices at a
   point, 32 slots a text; the cast, externs, enums and kinds below 65,535 records.
5. Every index in range, and every enumeration tag (kind, role, node, slot, effect,
   section kind) a known value.
6. Kinds: an enumeration exactly where the kind needs one; visit counts, states,
   seed and turn int facts; seed and turn of role `state` in the reserved scope, which
   is named `story`.
7. Every term range typed for its place, as in *Terms*, the stack never past 64.
8. Every node's, effect's and slot's fields as their kind says, unused ones zero.
9. A scene's entry present; a pool's pick at least one.

A string table is checked for its header, sorted unique nonzero ids, entries
parallel to them, names in its bytes, and every template's syntax; whether it serves
a graph is the separate check above. A graph that passes cannot make an executor
read out of bounds or meet a value of the wrong kind.
