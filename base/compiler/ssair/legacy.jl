# This file is a part of Julia. License is MIT: https://julialang.org/license

"""
    inflate_ir!(ci::CodeInfo, linfo::MethodInstance) -> ir::IRCode
    inflate_ir!(ci::CodeInfo, sptypes::Vector{VarState}, argtypes::Vector{Any}) -> ir::IRCode

Inflates `ci::CodeInfo`-IR to `ir::IRCode`-format.
This should be used with caution as it is a in-place transformation where the fields of
the original `ci::CodeInfo` are modified.
"""
function inflate_ir!(ci::CodeInfo, linfo::MethodInstance)
    sptypes = sptypes_from_meth_instance(linfo)
    argtypes, _ = matching_cache_argtypes(fallback_lattice, linfo)
    return inflate_ir!(ci, sptypes, argtypes)
end
function inflate_ir!(ci::CodeInfo, sptypes::Vector{VarState}, argtypes::Vector{Any})
    code = ci.code
    cfg = compute_basic_blocks(code)
    for i = 1:length(code)
        stmt = code[i]
        # Translate statement edges to bb_edges
        if isa(stmt, GotoNode)
            code[i] = GotoNode(block_for_inst(cfg, stmt.label))
        elseif isa(stmt, GotoIfNot)
            code[i] = GotoIfNot(stmt.cond, block_for_inst(cfg, stmt.dest))
        elseif isa(stmt, PhiNode)
            code[i] = PhiNode(Int32[block_for_inst(cfg, Int(edge)) for edge in stmt.edges], stmt.values)
        elseif isa(stmt, EnterNode)
            code[i] = EnterNode(stmt, stmt.catch_dest == 0 ? 0 : block_for_inst(cfg, stmt.catch_dest))
        end
    end
    nstmts = length(code)
    ssavaluetypes = ci.ssavaluetypes
    if !isa(ssavaluetypes, Vector{Any})
        ssavaluetypes = Any[ Any for i = 1:ssavaluetypes::Int ]
    end
    info = CallInfo[NoCallInfo() for i = 1:nstmts]
    stmts = InstructionStream(code, ssavaluetypes, info, ci.codelocs, ci.ssaflags)
    linetable = ci.linetable
    if !isa(linetable, Vector{LineInfoNode})
        linetable = collect(LineInfoNode, linetable::Vector{Any})::Vector{LineInfoNode}
    end
    meta = Expr[]
    return IRCode(stmts, cfg, linetable, argtypes, meta, sptypes)
end

"""
    inflate_ir(ci::CodeInfo, linfo::MethodInstance) -> ir::IRCode
    inflate_ir(ci::CodeInfo, sptypes::Vector{VarState}, argtypes::Vector{Any}) -> ir::IRCode
    inflate_ir(ci::CodeInfo) -> ir::IRCode

Non-destructive version of `inflate_ir!`.
Mainly used for testing or interactive use.
"""
inflate_ir(ci::CodeInfo, linfo::MethodInstance) = inflate_ir!(copy(ci), linfo)
inflate_ir(ci::CodeInfo, sptypes::Vector{VarState}, argtypes::Vector{Any}) = inflate_ir!(copy(ci), sptypes, argtypes)
function inflate_ir(ci::CodeInfo)
    # XXX the length of `ci.slotflags` may be different from the actual number of call
    # arguments, but we really don't know that information in this case
    argtypes = Any[ Any for i = 1:length(ci.slotflags) ]
    return inflate_ir(ci, VarState[], argtypes)
end

function replace_code_newstyle!(ci::CodeInfo, ir::IRCode)
    @assert isempty(ir.new_nodes)
    # All but the first `nargs` slots will now be unused
    nargs = length(ir.argtypes)
    resize!(ci.slotnames, nargs)
    resize!(ci.slotflags, nargs)
    resize!(ci.slottypes, nargs)
    stmts = ir.stmts
    code = ci.code = stmts.stmt
    ssavaluetypes = ci.ssavaluetypes = stmts.type
    codelocs = ci.codelocs = stmts.line
    ssaflags = ci.ssaflags = stmts.flag
    linetable = ci.linetable = ir.linetable
    for metanode in ir.meta
        push!(code, metanode)
        push!(codelocs, 1)
        push!(ssavaluetypes, Any)
        push!(ssaflags, IR_FLAG_NULL)
    end
    # Translate BB Edges to statement edges
    # (and undo normalization for now)
    for i = 1:length(code)
        stmt = code[i]
        if isa(stmt, GotoNode)
            code[i] = GotoNode(first(ir.cfg.blocks[stmt.label].stmts))
        elseif isa(stmt, GotoIfNot)
            code[i] = GotoIfNot(stmt.cond, first(ir.cfg.blocks[stmt.dest].stmts))
        elseif isa(stmt, PhiNode)
            code[i] = PhiNode(Int32[edge == 0 ? 0 : last(ir.cfg.blocks[edge].stmts) for edge in stmt.edges], stmt.values)
        elseif isa(stmt, EnterNode)
            code[i] = EnterNode(stmt, stmt.catch_dest == 0 ? 0 : first(ir.cfg.blocks[stmt.catch_dest].stmts))
        end
    end
end
