module ast.loops;

import ast.base, ast.scopes, ast.vardecl, ast.conditionals, ast.parse, ast.fun;
import ast.iterator, ast.int_literal, ast.fold, ast.tuples, ast.tuple_access;

// TODO: come up with a way to emit guards for a jump. this is necessary for continue/break to work correctly.

interface Breakable {
  string getContinueLabel();
  string getBreakLabel();
  Statement[] getOutsideGuards(); // guards at the point of exit; ie. break
  Statement[] getInsideGuards(); // guards at the point of loop end; ie. continue
}

TLS!(Stuple!(Breakable, Function)) breakable_context;
static this() { New(breakable_context); }

// NOTE: needs special attention, when dupping, to replace any references
// to it with the dupped version - see substituteBrkRef()
template DefaultBreakableImpl() {
  string chosenContinueLabel, chosenBreakLabel;
  Statement[] outsideGuards, insideGuards;
  override {
    string getContinueLabel() { return chosenContinueLabel; }
    string getBreakLabel() { return chosenBreakLabel; }
    Statement[] getOutsideGuards() { return outsideGuards; }
    Statement[] getInsideGuards() { return insideGuards; }
  }
}

void substituteBrkRef(Scope sc, Breakable what, Breakable substwith) {
  void recurse(ref Iterable it) {
    if (auto egj = fastcast!(ExecGuardsAndJump)(it)) {
      if (egj.brk is what) {
        it = fastalloc!(ExecGuardsAndJump)(egj.guards, egj.offsets, egj.modeContinue, substwith);
        return;
      }
    }
    it.iterate(&recurse);
  }
  sc.iterate(&recurse);
}

class WhileStatement : LineNumberedStatementClass, Breakable {
  Scope _body;
  Cond cond;
  Scope sup;
  Scope elsecmd;
  override WhileStatement dup() {
    auto res = fastalloc!(WhileStatement)();
    res._body = _body.dup;
    substituteBrkRef(res._body, this, res);
    res.cond = cond.dup;
    res.sup = sup; // goes upwards - don't dup!
    if (elsecmd) res.elsecmd = elsecmd.dup;
    return res;
  }
  mixin defaultIterate!(cond, _body, elsecmd);
  mixin defaultCollapse!();
  mixin DefaultBreakableImpl!();
  override {
    void emitLLVM(LLVMFile lf) {
      super.emitLLVM(lf);
      auto start = lf.allocLabel("while_start"), done = lf.allocLabel("while_done"), end = lf.allocLabel("while_end");
      if (!elsecmd) end = done;
      chosenContinueLabel = start;
      chosenBreakLabel = end;
      lf.emitLabel(start);
      cond.jumpOn(lf, false, done);
      _body.emitLLVM(lf);
      // TODO: rerun cond? check complexity?
      jump(lf, start);
      lf.emitLabel(done, true);
      if (elsecmd) {
        elsecmd.emitLLVM(lf);
        lf.emitLabel(end, true);
      }
    }
    string toString() { return Format("while("[], cond, "[]) { "[], _body._body, "}"[]); }
  }
}

import ast.aggregate;
Object gotWhileStmt(ref string text, ParseCb cont, ParseCb rest) {
  auto t2 = text;
  bool isStatic;
  if (t2.accept("static"[])) isStatic = true;
  bool forMode;
  if (!t2.accept("while"[])) {
    if (!t2.accept("for"[]))
      return null;
    forMode = true;
  }
  auto ws = new WhileStatement;
  auto sc = new Scope;
  ws.outsideGuards = sc.getGuards();
  ws.configPosition (text);
  sc.configPosition (text);
  ws.sup = sc;
  namespace.set(sc);
  scope(exit) namespace.set(sc.sup);
  if (!rest(t2, "cond"[], &ws.cond)) {
    if (forMode) return null;
    t2.failparse("Couldn't parse while cond"[]);
  }
  if (auto ew = fastcast!(ExprWrap) (ws.cond)) if (auto ce = fastcast!(CondExpr) (ew.ex)) {
    fail;
  }
  configure(ws.cond);
  ws.insideGuards = sc.getGuards();
  
  auto brbackup = *breakable_context.ptr();
  *breakable_context.ptr() = stuple(fastcast!(Breakable)(ws), sc.get!(Function));
  scope(exit) *breakable_context.ptr() = brbackup;
  
  if (isStatic) {
    auto aggr = fastcast!(AggrStatement)(sc._body);
    if (!aggr) text.failparse(Format("Malformed static while: "[], sc._body));
    if (!fastcast!(VarDecl) (aggr.stmts[0]))
      text.failparse(Format("Malformed static while (2): "[], aggr.stmts));
    aggr.stmts = null; // remove loop variable declaration/s
    
    auto backupfield = sc.field;
    Expr iter_expr;
    if (auto ilc = fastcast!(IterLetCond!(LValue)) (ws.cond)) iter_expr = ilc.iter;
    if (auto imc = fastcast!(IterLetCond!(MValue)) (ws.cond)) iter_expr = imc.iter;
    if (!iter_expr) text.failparse(Format("Could not interpret static-loop expression: ", ws.cond));
    
    auto iter = fastcast!(RichIterator) (iter_expr.valueType());
    if (!iter) text.failparse("static-loop expression not an iteratr! "[]);
    
    auto len = fastcast!(IntExpr) (collapse(iter.length(iter_expr)));
    // logln("collapse length is "[], collapse(iter.length(iter_expr)));
    if (!len) text.failparse("static-loop iterator length is not constant int! "[]);
    string t3;
    if (!len.num) text.failparse("static-loop must not be empty");
    for (int i = 0; i < len.num; ++i) {
      auto ival = foldex(iter.index(iter_expr, mkInt(i)));
      string t4 = t2;
      sc.field = backupfield.dup;
      string name;
      foreach (entry; sc.field) if (entry._0.length) if (auto v = fastcast!(Variable) (entry._1)) { name = entry._0; break; }
      sc.field.length = 0;
      sc.field ~= stuple(name, fastcast!(Object) (ival));
      sc.rebuildCache;
      auto popCache = pushCache(); scope(exit) popCache(); // same code is parsed multiple times - do not cache!
      Scope sc2;
      if (!rest(t4, "tree.scope"[], &sc2)) {
        t4.failparse("Couldn't parse during static-while expansion! "[]);
      }
      if (!t3) t3 = t4;
      else assert(t3 is t4);
      sc.field = backupfield;
      sc.addStatement(sc2);
    }
    t2 = t3;
  } else {
    if (!rest(t2, "tree.scope"[], &ws._body)) {
      if (forMode) return null;
      t2.failparse("Couldn't parse while body"[]);
    }
    if (t2.accept("then")) {
      if (!rest(t2, "tree.scope", &ws.elsecmd)) {
        t2.failparse("Couldn't parse while-then statement");
      }
    }
    sc.addStatement(ws);
  }
  text = t2;
  sc.rebuildCache;
  return sc;
}
mixin DefaultParser!(gotWhileStmt, "tree.stmt.while"[], "141"[]);

import tools.log;
class ForStatement : Statement, Breakable {
  Statement decl;
  Cond cond;
  Statement step;
  Scope _body;
  Scope elsecmd;
  override ForStatement dup() {
    auto res = fastalloc!(ForStatement)();
    res.decl = decl.dup;
    res.cond = cond.dup;
    res.step = step.dup;
    res._body = _body.dup;
    substituteBrkRef(res._body, this, res);
    if (res.elsecmd) res.elsecmd = elsecmd.dup;
    return res;
  }
  mixin DefaultBreakableImpl!();
  mixin defaultIterate!(decl, cond, step, _body, elsecmd);
  mixin defaultCollapse!();
  override void emitLLVM(LLVMFile lf) {
    // logln("start depth is "[], lf.currentStackDepth);
    decl.emitLLVM(lf);
    
    auto start = lf.allocLabel("for_start"), done = lf.allocLabel("for_done"), cont = lf.allocLabel("for_cont"), end = lf.allocLabel("for_end");
    chosenContinueLabel = cont;
    if (!elsecmd) end = done;
    chosenBreakLabel = end;
    
    lf.emitLabel(start);
    put(lf, "; jump on ", cond);
    cond.jumpOn(lf, false, done);
    _body.emitLLVM(lf);
    lf.emitLabel(cont, true);
    step.emitLLVM(lf);
    jump(lf, start);
    lf.emitLabel(done, true);
    if (elsecmd) {
      elsecmd.emitLLVM(lf);
      lf.emitLabel(end, true);
    }
  }
}

import ast.namespace;
Object gotForStmt(ref string text, ParseCb cont, ParseCb rest) {
  auto t2 = text;
  if (!t2.accept("("[])) return null;
  
  auto sc = fastalloc!(Scope)();
  auto backup = namespace();
  scope(exit) namespace.set(backup);
  namespace.set(sc);
  
  auto fs = new ForStatement;
  fs.outsideGuards = sc.getGuards();
  if (rest(t2, "tree.stmt.vardecl"[], &fs.decl) &&
      rest(t2, "cond"[], &fs.cond) && (configure(fs.cond), true) && t2.accept(";"[]) &&
      rest(t2, "tree.semicol_stmt"[], &fs.step) && t2.accept(")"[])
    )
  {
    fs.insideGuards = sc.getGuards();
    
    auto brbackup = *breakable_context.ptr();
    *breakable_context.ptr() = stuple(fastcast!(Breakable)(fs), namespace().get!(Function));
    scope(exit) *breakable_context.ptr() = brbackup;
    
    if (!rest(t2, "tree.scope"[], &fs._body))
      t2.failparse("Failed to parse 'for' body"[]);
    
    if (t2.accept("then")) {
      if (!rest(t2, "tree.scope", &fs.elsecmd)) {
        t2.failparse("Failed to parse for-else statement");
      }
    }
    text = t2;
    
    sc.addStatement(fs);
    return sc;
  } else t2.failparse("Failed to parse 'for' statement"[]);
}
mixin DefaultParser!(gotForStmt, "tree.stmt.for"[], "142"[], "for"[]);

class DoWhileExt : Statement, Breakable {
  Scope first, second, elsecmd;
  Cond cond;
  override DoWhileExt dup() {
    auto res = fastalloc!(DoWhileExt)();
    res.first = first.dup;
    substituteBrkRef(res.first, this, res);
    res.second = second.dup;
    substituteBrkRef(res.second, this, res);
    res.cond = cond.dup;
    if (elsecmd) res.elsecmd = elsecmd.dup;
    return res;
  }
  mixin DefaultBreakableImpl!();
  mixin defaultIterate!(first, second, cond);
  mixin defaultCollapse!();
  override void emitLLVM(LLVMFile lf) {
    mixin(mustOffset("0"));
    
    auto end = lf.allocLabel("extfor_end");
    
    first.needEntryLabel = true;
    chosenContinueLabel = first.entry();
    chosenBreakLabel = end;
    auto fdg = first.open(lf)(); // open and body
    cond.jumpOn(lf, false, first.exit());
    if (second) second.emitLLVM(lf);
    fdg(true); // close before jump! variables must be cleaned up .. don't set the label though
    jump(lf, first.entry());
    fdg(false); // close for real
    if (elsecmd) elsecmd.emitLLVM(lf);
    lf.emitLabel(end, true);
  }
}

Object gotDoWhileExtStmt(ref string text, ParseCb cont, ParseCb rest) {
  auto t2 = text;
  auto dw = new DoWhileExt;
  
  auto sc = new Scope;
  dw.outsideGuards = sc.getGuards();
  dw.insideGuards = dw.outsideGuards; // no initial condition == no difference here
  
  sc.configPosition(text);
  namespace.set(sc);
  scope(exit) namespace.set(sc.sup);
  
  auto brbackup = *breakable_context.ptr();
  *breakable_context.ptr() = stuple(fastcast!(Breakable)(dw), namespace().get!(Function));
  scope(exit) *breakable_context.ptr() = brbackup;
  
  if (!rest(t2, "tree.scope"[], &dw.first))
    t2.failparse("Couldn't parse scope after do"[]);
  auto backup = namespace();
  namespace.set(dw.first);
  scope(exit) namespace.set(backup);
  if (!t2.accept("while"[])) return null; // not a do/while extloop
  
  if (!rest(t2, "cond"[], &dw.cond))
    t2.failparse("Could not match do/while cond"[]);
  configure(dw.cond);
  
  if (t2.accept(";")) dw.second = null;
  else if (!rest(t2, "tree.scope"[], &dw.second))
    t2.failparse("do/while extended second scope not matched"[]);
  
  if (t2.accept("then")) {
    if (!rest(t2, "tree.scope", &dw.elsecmd)) {
      t2.failparse("Failed to parse do-while-do-else statement");
    }
  }
  text = t2;
  sc.addStatement(dw);
  return sc;
}
mixin DefaultParser!(gotDoWhileExtStmt, "tree.stmt.do_while_ext"[], "143"[], "do"[]);

class ExecGuardsAndJump : Statement {
  Statement[] guards;
  int[] offsets;
  bool modeContinue;
  Breakable brk;
  mixin defaultIterate!();
  mixin defaultCollapse!();
  mixin MyThis!("guards, offsets, modeContinue, brk"[]);
  override {
    ExecGuardsAndJump dup() {
      return this; // no mutable parts, no iteration
    }
    void emitLLVM(LLVMFile lf) {
      string targetlabel = modeContinue?brk.getContinueLabel():brk.getBreakLabel();
      if (!targetlabel) {
        logln("bad: break/continue context not initialized - break/continue in invalid loop? ", cast(void*) brk, " ", brk);
        asm { int 3; }
      }
      foreach_reverse (i, stmt; guards) {
        // justification for dup see class ReturnStmt in ast.returns
        stmt.dup().emitLLVM(lf);
      }
      jump(lf, targetlabel);
    }
  }
}

Object gotContinueOrBreak(bool gotContinue)(ref string text, ParseCb cont, ParseCb rest) {
  auto t2 = text;
  if (t2.accept("-")) return null; // break-prefix-in-variable
  auto brc = *breakable_context.ptr();
  auto fun = namespace().get!(Function);
  if (fun !is brc._1 || !brc._0)
    text.failparse("No continue-capable context found!"[]);
  auto sl = namespace().get!(ScopeLike);
  auto guards = sl.getGuards();
  auto guards2 = gotContinue?brc._0.getInsideGuards():brc._0.getOutsideGuards();
  if (guards2.length > guards.length)
    text.failparse("Invalid guard structure: "[], guards, " vs. "[], guards2);
  // wtf noop? o . o TODO figure out what I wanted here
  /*foreach (i, guard; guards2)
    if (guard !is guards2[i])
      text.failparse("Invalid guard structure: "[], guards, " vs. "[], guards2, " at "[], i);*/
  auto gos = sl.getGuardOffsets();
  return fastalloc!(ExecGuardsAndJump)(guards[guards2.length .. $], gos[guards2.length .. $], gotContinue, brc._0);
}
mixin DefaultParser!(gotContinueOrBreak!(true), "tree.semicol_stmt.continue", "103", "continue");
mixin DefaultParser!(gotContinueOrBreak!(false), "tree.semicol_stmt.break", "104", "break");
