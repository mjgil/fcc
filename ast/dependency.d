module ast.dependency;

/**
 * Dependency tracking is a way to tell the compiler your assumptions.
 * It applies in cases where you want to formalize a statement about your code
 * that is provided by a function, structure or module, in cases where the veracity
 * of the statement cannot be encoded merely in the type system.
 * For instance, if a 'sort' function provides in-place sort, you may wish
 * to depend on this property, despite the fact that there is no way to encode
 * in-place-ness in the typesystem!
 * Doing this in the comments is a good step; however, the compiler does not enforce
 * comment dependencies. How could it?
 * It is my opinion that most dependencies can be compiler-checked without necessarily
 * going as far as actually verifying the truth of the statement. To this end,
 * Neat introduces two keywords: "provide" and "depend".
 * Any function or struct can declare that it provides a certain property,
 * merely by stating 'provide "explanatory text"; '.
 * Then, any part that wishes to rely on this provision may
 * declare this dependency by saying 'depend StructName.FunctionName "explanatory text"; '.
 * When the explanatory text changes or is removed, the 'depend' statement will error.
 * The 'provide' keyword may also be augmented by the 'removed' qualifier, as in,
 * 'provide removed "explanatory text" "human-readable error message explaining the removal"; '.
 * This makes it easier to see where a certain property went.
 **/

import ast.base, ast.arrays, ast.literal_string, ast.fold, ast.namespace,
       ast.casting, ast.scopes, ast.fun,
       parseBase;

string get_id(string s) {
  // TODO unicode canonical form
  string h;
  const string hex = "0123456789abcdef";
  foreach (ch; s) {
    h ~= "" ~ hex[ch >> 4] ~ hex[ch & 15];
  }
  return "code_dependency_"~h;
}

class CodeDependency : Expr, Named {
  string info, removed_info;
  this(string i) { info = i; }
  string toString() { return qformat("dep ", info); }
  mixin defaultIterate!();
  mixin defaultCollapse!();
  override {
    string getIdentifier() { return get_id(info); }
    IType valueType() { return Single!(Void); }
    void emitLLVM(LLVMFile lf) { assert(false); }
    CodeDependency dup() { return this; }
  }
}

bool isString(IType it) { return test(Single!(Array, Single!(Char)) == resolveType(it)); }

Object gotProvide(bool Statement)(ref string text, ParseCb cont, ParseCb rest) {
  Expr ex;
  auto t2 = text;
  bool removed;
  if (t2.accept("removed")) removed = true;
  if (!rest(t2, "tree.expr"[], &ex) || !gotImplicitCast(ex, &isString))
    text.failparse("Expected string for 'provide'. ");
  auto se = fastcast!(StringExpr) (collapse(ex));
  if (!se)
    text.failparse("Expected constant string argument for 'provide'. ");
  
  auto ns = namespace();
  while (true) {
    if (auto sc = fastcast!(Scope) (ns)) ns = sc.sup;
    else break;
  }
  // logln("add into ", ns);
  auto cd = new CodeDependency(se.str);
  if (removed) {
    Expr rex;
    if (!rest(t2, "tree.expr"[], &rex) || !gotImplicitCast(rex, &isString))
    text.failparse("Expected second string for 'provide removed'. ");
    auto se2 = fastcast!(StringExpr) (collapse(rex));
    if (!se2)
      text.failparse("Expected second constant string argument for 'provide removed'. ");
    
    cd.removed_info = se2.str;
  }
  
  text = t2;
  static if (Statement) {
    ns.add(cd);
    return Single!(NoOp);
  } else {
    if (!text.accept(";"))
      text.failparse("semicolon expected");
    return cd;
  }
}
mixin DefaultParser!(gotProvide!(true), "tree.semicol_stmt.provide", "107", "provide");
mixin DefaultParser!(gotProvide!(false), "tree.toplevel.a_provide", null, "provide");
mixin DefaultParser!(gotProvide!(false), "struct_member.provide", null, "provide");

import ast.oop;
Object gotDepend(ref string text, ParseCb cont, ParseCb rest) {
  Expr ex;
  auto t2 = text;
  
  if (t2.accept("caller")) {
    if (!rest(t2, "tree.expr"[], &ex) || !gotImplicitCast(ex, &isString))
      text.failparse("Expected string for 'depend caller'. ");
    auto se = fastcast!(StringExpr) (collapse(ex));
    if (!se) text.failparse("Expected constant string argument for 'depend caller'. ");
    
    auto f = namespace().get!(Function);
    if (!f) text.failparse("No function context found: cannot add caller dependency");
    
    text = t2;
    f.calldeps ~= se.str;
    return Single!(NoOp);
  }
  
  string ident;
  t2.gotIdentifier(ident, true);
    // t2.failparse("Expected target identifier for 'depend'. ");
  // resolve
  Object res = namespace();
  Object llookup(string s, bool local = false) {
    if (auto it = fastcast!(IType) (res))
      res = fastcast!(Object) (resolveType(it));
    
    // logln("llookup ", s, " in ", res);
    if (fastcast!(Scope) (res)) { // if we're just starting to look for our function .. 
      if (auto fun = namespace().get!(Function)) {
        if (auto cl = fastcast!(Class) (fun.sup)) { // and we're in a class method ..
          // use the in-class lookup.
          res = fastcast!(Object) (cl.getRefType());
        }
      }
    }
    Class cl;
    if (auto _cl = fastcast!(Class) (res)) cl = _cl;
    if (auto cr = fastcast!(ClassRef) (res)) cl = cr.myClass;
    if (cl) {
      // special handling
      cl.parseMe;
      foreach (fun; cl.myfuns.funs) {
        if (fun.name == s) {
          fun.parseMe;
          return fun;
        }
      }
      if (auto res = cl.data.lookup(s, local)) return res;
      return cl.lookup(s, local);
    }
    if (auto ns = fastcast!(Namespace) (res))
      return ns.lookup(s, local);
    auto rns = fastcast!(RelNamespace) (res);
    IType it = fastcast!(IType) (res);
    if (!rns) if (auto srns = fastcast!(SemiRelNamespace) (res))
      rns = srns.resolve();
    if (rns) {
      if (!it) { logln(":( ", rns); fail; }
      return rns.lookupRel(s,
        new PlaceholderToken(it, "gotDepend lookup")
      ); // it's okay, it's just a CodeDependency
    }
    if (auto ex = fastcast!(Expr)(res)) {
      res = fastcast!(Object)(ex.valueType());
      return llookup(s, local);
    }
    return null;
  }
  auto start_ident = ident;
  while (ident.length) {
    // logln("ident: ", ident);
    while (ident.accept(".") || ident.accept("-")) { } // eat up
    auto fragment = ident;
  retry:
    // logln("retry fragment: ", fragment);
    auto r2 = llookup(fragment);
    if (!r2) {
      auto dotp = fragment.rfind(".");
      if (dotp != -1) {
        fragment = fragment[0 .. dotp];
        goto retry;
      }
      text.failparse("Failed to find '", fragment, "' in ", res);
    }
    res = r2;
    if (!ident.accept(fragment)) {
      fail;
    }
  }
  
  bool isString(IType it) { return test(Single!(Array, Single!(Char)) == resolveType(it)); }
  if (!rest(t2, "tree.expr"[], &ex) || !gotImplicitCast(ex, &isString))
    text.failparse("Expected provide string for 'depend'. ");
  auto se = fastcast!(StringExpr) (collapse(ex));
  if (!se)
    text.failparse("Expected constant string argument for 'provide'. ");
  
  auto name = get_id(se.str);
  
  if (auto cdep = fastcast!(CodeDependency) (llookup(name, true))) {
    if (cdep.removed_info)
      text.failparse("Dependency '", se.str, "' removed from ", start_ident, ": ",
        cdep.removed_info);
    
    text = t2;
    return Single!(NoOp); // satisfied
  }
  text.failparse("Dependency '", se.str, "' not provided by ", start_ident, " (", res, ")");
}
mixin DefaultParser!(gotDepend, "tree.semicol_stmt.depend", "106", "depend");

// called from Function.mkCall
extern(C) void dependency_checkCallerDeps(string[] strs) {
  if (!strs) return;
  auto fun = namespace().get!(Function);
  if (!fun) {
    logln("WARN: function '", fun.name, "' has caller dependency but is called from context that does not support 'provide'!");
    return;
  }
  foreach (str; strs) {
    auto name = get_id(str);
    auto test = fun.lookup(name, true);
    if (!test) {
      throw new Exception(qformat("dependency check failed: '", fun.name, "' does not implement \"", str, "\""));
    }
  }
}
pragma(set_attribute, dependency_checkCallerDeps, externally_visible);
