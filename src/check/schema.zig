//! The keys riverrun reserves for its own tags. riverrun carries tags and
//! never reads them, except these: `id`, a line's id, `gender` on a cast
//! entry, which a gender's words are chosen by, and a part's `weight` and
//! `migrate`. Every other key is the host's or a package's, held to a
//! `Checker.Schema`.

/// The key riverrun reserves for a line's id: `# id k7f3a2`.
pub const id_key = "id";
/// The key riverrun reserves on a cast entry for the gender its words are chosen by: `# gender feminine`.
pub const gender_key = "gender";
/// The key riverrun reserves on a pool's candidate for its weight in a draw: `# weight 3`.
pub const weight_key = "weight";
/// The key riverrun reserves on a rule that migrates a save: `# migrate 2`.
pub const migrate_key = "migrate";
