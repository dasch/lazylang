const std = @import("std");
const error_reporter = @import("error_reporter.zig");

/// Token types used by the lexer
pub const TokenKind = enum {
    eof,
    identifier,
    number,
    string,
    symbol,
    comma,
    colon,
    semicolon,
    equals,
    arrow,
    backslash,
    plus,
    minus,
    star,
    slash,
    ampersand,
    ampersand_ampersand,
    pipe_pipe,
    bang,
    equals_equals,
    bang_equals,
    less,
    greater,
    less_equals,
    greater_equals,
    dot,
    dot_dot_dot,
    l_paren,
    r_paren,
    l_bracket,
    r_bracket,
    l_brace,
    r_brace,
};

/// Token produced by the lexer
pub const Token = struct {
    kind: TokenKind,
    lexeme: []const u8,
    preceded_by_newline: bool,
    preceded_by_whitespace: bool, // True if any whitespace (space, tab, or newline) precedes this token
    line: usize, // 1-indexed line number
    column: usize, // 1-indexed column number
    offset: usize, // byte offset in source
    doc_comments: ?[]const u8, // Documentation comments preceding this token
};

/// Binary operators
pub const BinaryOp = enum {
    add,
    subtract,
    multiply,
    divide,
    logical_and,
    logical_or,
    pipeline,
    equal,
    not_equal,
    less_than,
    greater_than,
    less_or_equal,
    greater_or_equal,
    merge,
};

/// Unary operators
pub const UnaryOp = enum {
    logical_not,
};

/// Source location for an expression (reusing error_reporter's type)
pub const SourceLocation = error_reporter.SourceLocation;

/// An expression with source location information
pub const Expression = struct {
    data: ExpressionData,
    location: SourceLocation,
};

/// The actual expression data
pub const ExpressionData = union(enum) {
    integer: i64,
    float: f64,
    boolean: bool,
    null_literal,
    symbol: []const u8,
    identifier: []const u8,
    string_literal: []const u8,
    string_interpolation: StringInterpolation,
    lambda: Lambda,
    let: Let,
    where_expr: WhereExpr,
    unary: Unary,
    binary: Binary,
    application: Application,
    if_expr: If,
    when_matches: WhenMatches,
    array: ArrayLiteral,
    tuple: TupleLiteral,
    object: ObjectLiteral,
    object_extend: ObjectExtend,
    import_expr: ImportExpr,
    array_comprehension: ArrayComprehension,
    object_comprehension: ObjectComprehension,
    field_access: FieldAccess,
    index: Index,
    field_accessor: FieldAccessor,
    field_projection: FieldProjection,
    operator_function: BinaryOp,
};

pub const Lambda = struct {
    param: *Pattern,
    body: *Expression,
};

pub const Let = struct {
    pattern: *Pattern,
    value: *Expression,
    body: *Expression,
    doc: ?[]const u8, // Combined documentation comments
};

pub const WhereBinding = struct {
    pattern: *Pattern,
    value: *Expression,
    doc: ?[]const u8,
};

pub const WhereExpr = struct {
    expr: *Expression,
    bindings: []WhereBinding,
};

pub const Unary = struct {
    op: UnaryOp,
    operand: *Expression,
};

pub const Binary = struct {
    op: BinaryOp,
    left: *Expression,
    right: *Expression,
};

pub const Application = struct {
    function: *Expression,
    argument: *Expression,
};

pub const If = struct {
    condition: *Expression,
    then_expr: *Expression,
    else_expr: ?*Expression,
};

pub const WhenMatches = struct {
    value: *Expression,
    branches: []MatchBranch,
    otherwise: ?*Expression,
};

pub const MatchBranch = struct {
    pattern: *Pattern,
    expression: *Expression,
};

pub const ConditionalElement = struct {
    expr: *Expression,
    condition: *Expression,
};

pub const ArrayElement = union(enum) {
    normal: *Expression,
    spread: *Expression,
    conditional_if: ConditionalElement,
    conditional_unless: ConditionalElement,
};

pub const ArrayLiteral = struct {
    elements: []ArrayElement,
};

pub const TupleLiteral = struct {
    elements: []*Expression,
};

pub const ObjectFieldKey = union(enum) {
    static: []const u8,
    dynamic: *Expression,
};

pub const ObjectField = struct {
    key: ObjectFieldKey,
    value: *Expression,
    is_patch: bool, // true if no colon (merge), false if colon (overwrite)
    doc: ?[]const u8, // Combined documentation comments
    key_location: ?error_reporter.SourceLocation, // Location of the field key for error reporting
};

pub const ObjectLiteral = struct {
    fields: []ObjectField,
    module_doc: ?[]const u8, // Module-level documentation
};

pub const ObjectExtend = struct {
    base: *Expression,
    fields: []ObjectField,
};

pub const ImportExpr = struct {
    path: []const u8,
    path_location: SourceLocation, // Location of the module path string
};

pub const StringInterpolation = struct {
    parts: []StringPart,
};

pub const StringPart = union(enum) {
    literal: []const u8,
    interpolation: *Expression,
};

pub const ForClause = struct {
    pattern: *Pattern,
    iterable: *Expression,
};

pub const ArrayComprehension = struct {
    body: *Expression,
    clauses: []ForClause,
    filter: ?*Expression,
};

pub const ObjectComprehension = struct {
    key: *Expression,
    value: *Expression,
    clauses: []ForClause,
    filter: ?*Expression,
};

pub const FieldAccess = struct {
    object: *Expression,
    field: []const u8,
    field_location: SourceLocation, // Location of the field name for error reporting
};

pub const Index = struct {
    object: *Expression,
    index: *Expression,
};

pub const FieldAccessor = struct {
    fields: [][]const u8, // Chain of field names, e.g. ["user", "address"]
};

pub const FieldProjection = struct {
    object: *Expression,
    fields: [][]const u8, // List of fields to extract
};

/// A pattern for destructuring
pub const Pattern = struct {
    data: PatternData,
    location: SourceLocation, // Use same location type as Expression
};

pub const PatternData = union(enum) {
    identifier: []const u8,
    integer: i64,
    float: f64,
    boolean: bool,
    null_literal,
    symbol: []const u8,
    string_literal: []const u8,
    tuple: TuplePattern,
    array: ArrayPattern,
    object: ObjectPattern,
};

pub const TuplePattern = struct {
    elements: []*Pattern,
};

pub const ArrayPattern = struct {
    elements: []*Pattern,
    rest: ?[]const u8, // Optional rest identifier (e.g., "tail" in [head, ...tail])
};

pub const ObjectPattern = struct {
    fields: []ObjectPatternField,
};

pub const ObjectPatternField = struct {
    key: []const u8,
    pattern: *Pattern, // Either identifier for extraction or literal for matching
};
