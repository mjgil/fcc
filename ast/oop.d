module ast.oop;

import ast.parse, ast.base, ast.dg, ast.int_literal, ast.fun,
  ast.namespace, ast.structure, ast.structfuns, ast.pointer,
  ast.arrays, ast.aggregate, ast.literals, ast.slice, ast.nestfun,
  ast.tenth;

import tools.functional: map;

/*
  An abstract function is a function that does not define a body.
  An abstract class is a class that declares abstract member functions,
    or inherits an abstract class without implementing its abstract member functions.
  Abstract classes must be declared with the 'abstract' keyword.
  Abstract classes can not be allocated.
 */

string datatollvm(LLVMFile lf, string ident, ubyte[] s) {
  return qformat("bitcast([", s.length, " x i8]* @", allocConstant(lf, ident, cast(ubyte[]) s, true), " to i8*)");
}

string datatollvm(LLVMFile lf, string ident, string[] arr) {
  return qformat("bitcast([", arr.length, " x i32]* @", allocLongstant(lf, ident, arr, true), " to i8*)");
}

struct RelFunSet {
  Stuple!(RelFunction, string, IType[])[] set;
  string toString() {
    return Format(set /map/ ex!("a, b, c -> b"[]));
  }
  RelFunction[] lookup(string name) {
    RelFunction[] res;
    foreach (entry; set)
      if (entry._1 == name) res ~= entry._0;
    return res;
  }
  static bool IType_eq(IType[] a, IType[] b) {
    if (a.length != b.length) return false;
    // null stuff, like null return types, is taken as a wildcard
    foreach (i, v; a) if (v && v != b[i]) return false;
    return true;
  }
  RelFunction lookup(string st, IType[] types) {
    foreach (entry; set) {
      if (entry._1 == st && IType_eq(entry._2, types))
        return entry._0;
    }
    return null;
  }
  RelFunction hasLike(Function f) {
    return lookup(f.name, f.type.alltypes());
  }
  void add(string name, RelFunction rf) {
    set ~= stuple(rf, name, rf.type.alltypes());
  }
  // append to set those of rfs.set _not_ yet in set
  void fillIn(RelFunSet rfs) {
    foreach (entry; rfs.set) {
      if (!lookup(entry._1, entry._2))
        set ~= entry;
    }
  }
}

import tools.log, tools.base: max;
import ast.vardecl;
class VTable {
  RelFunction[] funs;
  Class parent;
  static bool Arglist_eq(Argument[] a, Argument[] b) {
    if (a.length != b.length) return false;
    foreach (i, v; a) if (v.type != b[i].type) return false;
    return true;
  }
  bool defines(Function fun) {
    foreach (f2; funs) {
      if (f2.name == fun.name &&
          Arglist_eq(f2.getParams(false), fun.getParams(false))) return true;
    }
    return false;
  }
  Object lookup(string name, Expr classref) {
    int base = -1;
    Function[] res;
    foreach (id, fun; funs)
      if (fun.name == name) {
        if (!classref) return fun;
        if (base == -1) // lazy init
          base = (parent.parent?parent.parent.getClassinfo().length:1);
        res ~= 
          new PointerFunction!(NestedFunction) (
            tmpize_maybe(classref, delegate Expr(Expr classref) {
              return fastalloc!(DgConstructExpr)(
                fastalloc!(DerefExpr)(
                  lookupOp("+"[],
                    fastalloc!(DerefExpr)(
                      reinterpret_cast(
                        fastalloc!(Pointer)(fastalloc!(Pointer)(fun.typeAsFp())),
                        classref)),
                    mkInt(id+base))),
                reinterpret_cast(voidp, classref));
            })
          );
      }
    // logln(parent.name, ": "[], name, " => "[], res);
    if (res.length == 1) return fastcast!(Object) (res[0]);
    if (res.length == 0) return null;
    return fastalloc!(OverloadSet)(res[0].name, res);
  }
  Object lookupFinal(string name, Expr classref) {
    auto classval = fastalloc!(DerefExpr)(reinterpret_cast(voidpp, classref));
    Function[] res;
    if (auto list = parent.overrides.lookup(name))
      res ~= list;
    // return fastcast!(Function) (fastcast!(RelFunction) (*p).transform(classval));
    foreach (fun; funs)
      if (fun.name == name)
        res ~= fun;
    foreach (ref entry; res)
      entry = fastcast!(Function) (
        fastcast!(RelFunction) (entry).transform(classval)
      );
    if (res.length == 1) return fastcast!(Object) (res[0]);
    if (res.length == 0) return null;
    return fastalloc!(OverloadSet)(res[0].name, res);
  }
}

class LazyDeltaInt : Expr {
  int delegate() dg;
  int delta;
  this(int delegate() dg, int d = 0) { this.dg = dg; delta = d; }
  mixin defaultIterate!();
  override {
    string toString() { return qformat("ldi(", dg(), " + ", delta, ")"); }
    IType valueType() { return Single!(SysInt); }
    LazyDeltaInt dup() { return new LazyDeltaInt(dg, delta); }
    void emitLLVM(LLVMFile lf) {
      auto res = dg() + delta;
      push(lf, res);
    }
  }
}

static this() {
  foldopt ~= delegate Itr(Itr it) {
    auto ldi = fastcast!(LazyDeltaInt)(it);
    if (!ldi) return null;
    auto val = ldi.dg() + ldi.delta;
    return mkInt(val);
  };
}

// lookupRel in interfaces/classes takes the class *reference*.
// This is IMPORTANT for compat with using.

class Intf : Namespace, IType, Tree, RelNamespace, IsMangled, hasRefType {
  string name;
  bool predecl;
  mixin TypeDefaults!();
  private this() { }
  mixin DefaultDup!();
  mixin defaultIterate!();
  override {
    void emitLLVM(LLVMFile lf) { }
    string llvmSize() { assert(false); }
    string llvmType() { assert(false); }
    bool isTempNamespace() { return false; }
    bool isPointerLess() { return false; }
    bool isComplete() { return true; }
    bool returnsInMemory() { return false; }
  }
  IntfRef getRefType() { return fastalloc!(IntfRef)(this); }
  string toString() { return "interface "~name; }
  string mangle() { return qformat("interface_", mangle_id); }
  override string mangle(string name, IType type) { assert(false); }
  bool weak;
  override void markWeak() { weak = true; }
  override void markExternC() { }
  override string mangleSelf() { return mangle(); }
  Function[] funs;
  Intf[] parents;
  Function[] getAbstractFuns() {
    Function[] res = funs;
    foreach (parent; parents) res ~= parent.getAbstractFuns();
    return res;
  }
  string mangle_id;
  this(string name) {
    this.name = name;
    mangle_id = namespace().mangle(name, this);
  }
  bool declares(string name) {
    foreach (fun; funs) if (fun.name == name) return true;
    foreach (par; parents) if (par.declares(name)) return true;
    return false;
  }
  int clsize() {
    int res;
    if (!parents.length) res = 1;
    else {
      res = parents[0].clsize();
      foreach (par; parents[1 .. $])
        res += par.clsize();
    }
    return res + funs.length;
  }
  int own_offset;
  void initOffset() { own_offset = clsize() - funs.length; }
  // offset is size of preceding data, in steps of nativePtrSize
  string[] genVTable(ref string offset, RelFunSet overrides, LLVMFile lf) {
    string[] res;
    if (!parents.length) {
      res ~= qformat("inttoptr(i32 -", offset, " to i8*)");
      offset = lladd(offset, "1");
    }
    else {
      res = parents[0].genVTable(offset, overrides, lf);
      foreach (par; parents[1 .. $])
        res ~= par.genVTable(offset, overrides, lf);
    }
    
    foreach (fun; funs)
      if (auto rel = overrides.hasLike(fun)) {
        auto fmn = rel.mangleSelf();
        auto reltype = typeToLLVM(rel.getPointer().valueType());
        res ~= qformat("bitcast(", reltype, " @", fmn, " to i8*)");
        if (lf) lf.decls[fmn] = declare(rel, fmn);
      } else
        throw new Exception(
          Format("Cannot generate classinfo for "[], this.name,
            ": "[], fun.name, " not overridden. "[]));
    
    return res;
  }
  string getIntfinfoDataPtr(LLVMFile lf) {
    auto prefix = mangle_id;
    string[] res;
    res ~= qformat(this.name.length);
    res ~= qformat("ptrtoint(i8* ", datatollvm(lf, prefix~"_name", cast(ubyte[]) this.name), " to i32)");
    {
      string[] pp;
      foreach (intf; parents)
        pp ~= intf.getIntfinfoDataPtr(lf);
      res ~= qformat(pp.length);
      res ~= qformat("ptrtoint(i8* ", datatollvm(lf, prefix~"_parents", pp), " to i32)");
    }
    return qformat("ptrtoint(i8* ", datatollvm(lf, prefix~"_intfinfo", res), " to i32)");
  }
  import ast.index;
  Object lookupIntf(string name, Expr intp) {
    assert(own_offset);
    Function[] set;
    foreach (id, fun; funs) {
      if (fun.name == name) {
        if (!intp) return fun;
        auto fntype = fun.getPointer().valueType();
        auto pp_fntype = fastalloc!(Pointer)(fastalloc!(Pointer)(fntype));
        auto pp_int = Single!(Pointer, Single!(Pointer, Single!(SysInt)));
        // *(*fntype**:intp)[id].toDg(void**:intp + **int**:intp)
        set ~= new PointerFunction!(NestedFunction) (
          tmpize_maybe(intp, delegate Expr(Expr intp) {
            return fastalloc!(DgConstructExpr)(
              new PA_Access(fastalloc!(DerefExpr)(reinterpret_cast(pp_fntype, intp)), mkInt(id + own_offset)),
              lookupOp("+"[],
                reinterpret_cast(fastalloc!(Pointer)(voidp), intp),
                fastalloc!(DerefExpr)(fastalloc!(DerefExpr)(reinterpret_cast(pp_int, intp)))
              )
            );
          })
        );
      }
    }
    if (!set) return null;
    if (set.length == 1) return set[0];
    return fastalloc!(OverloadSet)(set[0].name, set);
  }
  override Object lookupRel(string name, Expr base, bool isDirectLookup = true) {
    if (!base) {
      if (name == "__name"[]) // T.name
        return fastcast!(Object) (mkString(this.name));
      if (name == "__mangle"[])
        return fastcast!(Object) (mkString(this.mangle_id));
      return lookupIntf(name, null);
    }
    if (!fastcast!(IntfRef) (base.valueType())) {
      logln("Bad intf ref: "[], base);
      fail;
    }
    if (name == "this"[]) return fastcast!(Object)~ base;
    // haaaaax
    if (auto res = lookup(name, true)) {
      if (auto rt = fastcast!(RelTransformable) (res))
        return rt.transform(base);
      return res;
    }
    return lookupIntf(name, base);
  }
  // takes ownership of offs
  Function lookupClass(string name, LazyDeltaInt offs, Expr classref) {
    assert(own_offset, this.name~": interface lookup for "~name~" but classinfo uninitialized. "[]);
    foreach (id, fun; funs) {
      if (fun.name == name) {
        // *(*fntype**:classref)[id + offs].toDg(void*:classref)
        auto fntype = fun.getPointer().valueType();
        auto pp_fntype = fastalloc!(Pointer)(fastalloc!(Pointer)(fntype));
        return new PointerFunction!(NestedFunction)(
          fastalloc!(DgConstructExpr)(
            new PA_Access(fastalloc!(DerefExpr)(reinterpret_cast(pp_fntype, classref)), lookupOp("+"[], offs, mkInt(id + own_offset))),
            reinterpret_cast(voidp, classref)
          )
        );
      }
    }
    scope(exit) delete offs;
    foreach (par; parents) {
      if (auto res = par.lookupClass(name, offs.dup, classref)) return res;
      offs.delta += par.clsize;
    }
    return null;
  }
  void getLeaves(void delegate(Intf) dg) {
    if (!parents.length) dg(this);
    else foreach (parent; parents) parent.getLeaves(dg);
  }
}

class ClassRef : Type, SemiRelNamespace, Formatable, Tree, Named, SelfAdding, IsMangled, ExprLikeThingy, ReferenceType {
  Class myClass;
  this(Class cl) { myClass = cl; if (!cl) fail; }
  override {
    bool isPointerLess() { return false; }
    RelNamespace resolve() { return myClass; }
    string toString() { return Format("ref ", myClass); }
    bool addsSelf() { return true; }
    string getIdentifier() { return myClass.name; }
    string llvmSize() { if (nativePtrSize == 4) return "4"; fail; }
    string llvmType() { if (nativePtrSize == 4) return "i8*"; fail; }
    void markWeak() { myClass.markWeak(); }
    void markExternC() { }
    string mangle() { return "ref_"~myClass.mangle(); }
    string mangleSelf() { return mangle(); }
    bool returnsInMemory() { return false; }
    int opEquals(IType type) {
      if (!super.opEquals(type)) return false;
      // logln("test "[], type, " against "[], this);
      // return myClass == (fastcast!(ClassRef) (resolveType(type))).myClass;
      return myClass.mangle() == (fastcast!(ClassRef) (resolveType(type))).myClass.mangle(); // see IntfRef
    }
    Expr format(Expr ex) {
      return iparse!(Expr, "gen_obj_toString_call_again_o_o"[], "tree.expr"[])
                    (`obj.toString()`, "obj"[], lvize(ex));
    }
    ClassRef dup() { return fastalloc!(ClassRef)(myClass.dup); }
    void emitLLVM(LLVMFile lf) { myClass.emitLLVM(lf); }
    void iterate(void delegate(ref Iterable) dg, IterMode mode = IterMode.Lexical) { myClass.iterate(dg, mode); }
  }
}

class IntfRef : Type, SemiRelNamespace, Tree, Named, SelfAdding, IsMangled, ExprLikeThingy, ReferenceType {
  Intf myIntf;
  this(Intf i) { myIntf = i; }
  override {
    RelNamespace resolve() { return myIntf; }
    string toString() { return Format("ref "[], myIntf); }
    string getIdentifier() { return myIntf.name; }
    bool isPointerLess() { return false; }
    bool addsSelf() { return true; }
    string llvmSize() { if (nativePtrSize == 4) return "4"; fail; }
    string llvmType() { if (nativePtrSize == 4) return "i8*"; fail; }
    void markWeak() { } // nothing emitted, ergo no-op
    void markExternC() { }
    string mangle() { return "intfref_"~myIntf.mangle(); }
    string mangleSelf() { return mangle(); }
    int opEquals(IType type) {
      if (!super.opEquals(type)) return false;
      return myIntf.mangleSelf() == (fastcast!(IntfRef) (resolveType(type))).myIntf.mangleSelf(); // cheap hack to match obsoleted types (TODO fix properly)
    }
    IntfRef dup() { return fastalloc!(IntfRef)(myIntf.dup); }
    void emitLLVM(LLVMFile lf) { myIntf.emitLLVM(lf); }
    void iterate(void delegate(ref Iterable) dg, IterMode mode = IterMode.Lexical) { myIntf.iterate(dg, mode); }
  }
}

class SuperType : IType, RelNamespace {
  ClassRef baseType;
  this(ClassRef cr) { baseType = cr; }
  override {
    string toString() { return Format(baseType, ".super ("[], baseType.myClass.parent.myfuns.funs, ")"[]); }
    string mangle() { return Format("_super_"[], baseType.mangle()); }
    int opEquals(IType it) { return false; /* wut */ }
    bool isPointerLess() { return false; }
    bool returnsInMemory() { assert(false); }
    string llvmSize() {
      if (nativePtrSize == 4) return "4";
      fail;
    }
    string llvmType() { return "invalid"; }
    override bool isComplete() { return true; }
    Object lookupRel(string name, Expr base, bool isDirectLookup = true) {
      auto sup2 = fastcast!(SuperType) (base.valueType());
      if (sup2 !is this) fail;
      // iterate parents
      Class parent_class = baseType.myClass.parent;
      while (parent_class) {
        auto suptable = parent_class.myfuns;
        if (auto res = suptable.lookupFinal(name, reinterpret_cast(parent_class.getRefType, base)))
          return res;
        parent_class = parent_class.parent;
      }
      return null;
    }
    bool isTempNamespace() { return true; }
    IType proxyType() { return null; }
  }
}

import ast.modules, ast.returns, ast.scopes, ast.stringparse;
class Class : Namespace, StructLike, RelNamespace, IType, Tree, hasRefType {
  VTable myfuns;
  Structure data;
  string name;
  Class parent;
  // if true, newly added functions are required to override a function
  // specified by inheritance. This avoids cases where a function is intended
  // to be overridden but is accidentally added as a new class function.
  bool overridingFunctionState;
  override {
    bool immutableNow() { return data.immutableNow(); }
    bool isPacked() { return data.isPacked(); }
    int numMembers() { return data.numMembers(); }
    string getIdentifier() { return name; }
  }
  Function[] getAbstractFuns() {
    parseMe();
    Function[] res;
    // An abstract class is a class that declares abstract member functions,
    foreach (fun; myfuns.funs) if (fun.isabstract) res ~= fun;
    // or inherits an abstract class without implementing its abstract member functions,
    // or inherits an interface without implementing its functions.
    if (parent)
      foreach (fun; parent.getAbstractFuns()) {
        if (auto f2 = overrides.hasLike(fun)) {
          fun = f2;
        }
        if (fun.isabstract) res ~= fun;
      }
    foreach (intf; iparents) foreach (ifun; intf.getAbstractFuns()) {
      if (auto f2 = overrides.hasLike(ifun)) {
        ifun = f2;
      }
      if (ifun.isabstract || (!ifun.tree && !ifun.coarseSrc && !ifun.inParse)) {
        res ~= ifun;
      }
    }
    return res;
  }
  bool isabstract() {
    if (!coarseSrc && !data) return false; // tentatively assume we're not abstract
    return getAbstractFuns().length > 0;
  }
  bool declared_abstract;
   
  Intf[] iparents;
  RelMember ctx; // context of parent reference
  Expr delegate(Expr) ctxFixup;
  IType rtpt;
  
  string coarseSrc;
  Namespace coarseCtx;
  IModule coarseMod;
  void fixupInterfaceAbstracts() {
    auto abstracts = getAbstractFuns();
    foreach (fun; abstracts) {
      if (!fun.tree && !fun.coarseSrc) {
        auto rf = fastalloc!(RelFunction)(this);
        rf.type = fun.type;
        rf.name = fun.name;
        rf.autogenerated = true;
        fastcast!(IsMangled) (rf).markWeak();
        add(rf);
        
        rf.fixup;
        mkAbstract(rf);
        fastcast!(Module) (current_module()).entries ~= rf;
      }
    }
  }
  string offset_cached;
  bool cached_offset;
  string offsetOfVTable() {
    parseMe;
    if (cached_offset) return offset_cached;
    if (!finalized) {
      offset_cached = data.offsetOfNext(voidp);
      // need to add those now or risk invalidating our offset later
      // Note that it is NOT a problem if members get added
      // after the slot pointers, because as of now the interface
      // offset is fixed and cached.
      addSlotPointers;
      finalized = true;
      // logln(name, ": for ", data, ", offset of next voidp is ", offset_cached);
      cached_offset = true;
      return offset_cached;
    }
    logln(name, ": queried offsetOfVTable but already finalized");
    fail;
  }
  void parseMe() {
    if (!coarseSrc || !coarseCtx || !coarseMod) {
      if (!data) {
        asm { int 3; }
      }
      return;
    }
    
    if (parent) {
      parent.parseMe;
      data = parent.data.dup();
    }
    
    auto cstemp = coarseSrc;
    coarseSrc = null; // prevent infloop with the RelMember
    auto csstart = cstemp;
    scope(success) {
      if (isabstract() && !declared_abstract) {
        csstart.failparse("Class '"[], name, "' contains abstract functions ("[],
          (getAbstractFuns() /map/ ex!("x -> x.name"[])).join(", "[]), "), but is not declared abstract! "[]);
      }
    }
    
    if (rtpt) {
      if (auto c = fastcast!(RelMember) (lookup("__context"[], true))) ctx = c; // reuse parent's
      else ctx = fastalloc!(RelMember)("__context"[], rtpt, this);
    }
    
    auto backup = namespace();
    scope(exit) namespace.set(backup);
    namespace.set(coarseCtx);
    coarseCtx = null;
    
    auto backupmod = current_module();
    scope(exit) current_module.set(backupmod);
    current_module.set(coarseMod);
    coarseMod = null;
    
    auto popCache = pushCache(); scope(exit) popCache();
    
    string t2 = cstemp;
    coarseSrc = null;
    
    auto classref = fastcast!(ClassRef) (getRefType());
    
    auto rtptbackup = RefToParentType();
    scope(exit) RefToParentType.set(rtptbackup);
    RefToParentType.set(classref);
    
    auto rtpmbackup = *RefToParentModify();
    scope(exit) *RefToParentModify.ptr() = rtpmbackup;
    *RefToParentModify.ptr() = delegate Expr(Expr baseref) { return baseref; /* no-op, classes are already ref */ };
    
    if (!t2.accept("{"[])) t2.failparse("Missing opening bracket for class def"[]);
    
    bool parsed(bool matchGroup = true, bool overrideKeyword = false) {
      if (matchGroup) {
        while (true) {
          if (parsed(false, overrideKeyword)) continue;
          if (t2.accept("}")) return true;
          t2.failparse("expected class statement or closing bracket");
        }
      } else {
        if (t2.accept("override")) {
          bool isGroup = t2.accept("{");
          return parsed(isGroup, true);
        }
        auto backup = overridingFunctionState;
        scope(exit) overridingFunctionState = backup;
        overridingFunctionState = overrideKeyword;
        auto t3 = t2;
        try if (matchStructBodySegment(t2, this, null, false, false)) return true;
        catch (Exception ex) {
          t3.failparse(ex);
        }
        return false;
      }
    }
    parsed();
    // logln("register class "[], cl.name);
    try finalize;
    catch (Exception ex) cstemp.failparse(ex);
    coarseSrc = null;
  }
  
  string toString() { return name; }
  override int opEquals(Object obj2) {
    if (this is obj2) return true;
    auto cl2 = fastcast!(Class) (obj2);
    if (!cl2) return false;
    return mangle() == cl2.mangle();
  }
  override string llvmSize() { /*logln("class size => ", classSize(true));*/ return classSize(true); }
  override string llvmType() { return data.llvmType(); }
  override bool isPointerLess() { return false; }
  override bool isComplete() { return true; }
  void getIntfLeaves(void delegate(Intf) dg) {
    parseMe;
    foreach (intf; iparents)
      intf.getLeaves(dg);
  }
  RelFunSet overrides;
  string mangle_id;
  bool weak;
  void markWeak() {
    parseMe;
    weak = true;
    foreach (fun; myfuns.funs)
      (fastcast!(IsMangled) (fun)).markWeak();
    foreach (tup; overrides.set)
      (fastcast!(IsMangled) (tup._0)).markWeak();
  }
  override string mangle() { return mangle_id; }
  override Class dup() { return this; }
  override bool returnsInMemory() { return false; }
  bool isTempNamespace() { return false; }
  this(string name, Class parent) {
    mangle_id = namespace().mangle(name, null);
    auto root = fastcast!(ClassRef)  (sysmod?sysmod.lookup("Object"[]):null);
    if (root) {
      if (name == "Object"[])
        throw new Exception("Can't redefine Object! "[]);
    } else {
      if (name != "Object"[])
        throw new Exception("Object must be first class defined! "[]);
    }
    if (!parent) parent = root?root.myClass:null;
    this.name = name;
    New(myfuns);
    myfuns.parent = this;
    this.parent = parent;
    if (!parent) {
      New(data, cast(string) null);
      fastalloc!(RelMemberLV)("__vtable"[], voidp, data);
    }
    if (auto it = RefToParentType()) {
      rtpt = it;
      ctxFixup = *RefToParentModify.ptr();
    }
    sup = namespace();
    auto mod = fastcast!(Module) (current_module());
    if (namespace() !is mod) {
      mod.entries ~= this;
    }
  }
  bool finalized;
  void addSlotPointers() {
    if (iparents.length) {
      getIntfLeaves((Intf) {
        fastalloc!(RelMember)(cast(string) null, voidp, data);
      });
    }
  }
  void genDefaultFuns() {
    if (sysmod && parent /* exclude Object */) {
      IType[1] tostring_ret;
      tostring_ret[0] = Single!(Array, Single!(Char));
      bool hasToStringOverride = !!overrides.lookup("toString"[], tostring_ret[]);
      auto cur = this;
      while (cur.parent) {
        auto tsv = fastcast!(RelFunction) (cur.overrides.lookup("toString"[], tostring_ret[]));
        hasToStringOverride |= tsv && !tsv.autogenerated;
        cur = cur.parent;
      }
      if (!hasToStringOverride) {
        auto rf = fastalloc!(RelFunction)(this);
        New(rf.type);
        rf.name = "toString";
        rf.type.ret = Single!(Array, Single!(Char));
        rf.sup = this;
        rf.autogenerated = true;
        (fastcast!(IsMangled) (rf)).markWeak();
        _add("toString"[], rf);
        
        auto backup = namespace();
        namespace.set(rf);
        scope(exit) namespace.set(backup);
        
        rf.fixup;
        rf.addStatement(fastalloc!(ReturnStmt)(mkString(name)));
        fastcast!(Module) (current_module()).entries ~= rf;
      }
    }
    {
      auto rf = fastalloc!(RelFunction)(this);
      New(rf.type);
      rf.name = "dynamicCastTo";
      rf.type.ret = voidp;
      rf.type.params ~= Argument(Single!(Array, Single!(Char)), "id"[]);
      rf.sup = this;
      (fastcast!(IsMangled) (rf)).markWeak();
      add(rf);
      auto backup = namespace();
      scope(exit) namespace.set(backup);
      namespace.set(rf);
      rf.fixup;
      
      auto sc = new Scope;
      namespace.set(sc);
      // TODO: switch
      auto as = new AggrStatement;
      string intf_offset;
      auto streq = sysmod.lookup("streq"[]);
      assert(!!streq);
      void handleIntf(Intf intf) {
        // logln(name, ": offset for intf "[], intf.name, ": "[], intf_offset);
        as.stmts ~= iparse!(Statement, "cast_branch_intf"[], "tree.stmt"[])(`if (streq(id, _test)) return void*:(void**:this + offs);`[],
          namespace(), "_test"[], mkString(intf.mangle_id), "offs"[], llvmval(intf_offset)
        );
        if (intf.parents) foreach (ip; intf.parents) handleIntf(ip);
        else intf_offset = lladd(intf_offset, "1");
      }
      void handleClass(Class cl) {
        as.stmts ~= fastcast!(Statement) (runTenthPure((void delegate(string,Object) dg) {
          dg("id"[], rf.lookup("id"[]));
          dg("this"[], rf.lookup("this"[]));
          dg("_test"[], fastcast!(Object) (mkString(cl.mangle_id)));
          dg("streq"[], sysmod.lookup("streq"[]));
        }, parseTenth(`
          (make-if
            (make-exprwrap (make-call streq (make-tuple-expr (list id _test))))
            '(make-return (reinterpret-cast (pointer-to (basic-type 'void)) this)))
        `)));
        if (cl.parent) handleClass(cl.parent);
        intf_offset = cl.offsetOfVTable();
        // intf_offset = cl.classSize(false);
        intf_offset = llAlign(intf_offset, voidp);
        intf_offset = lldiv(intf_offset, "4");
        foreach (intf; cl.iparents)
          handleIntf(intf);
      }
      handleClass(this);
      as.stmts ~= fastalloc!(ReturnStmt)(fastcast!(Expr) (sysmod.lookup("null"[])));
      sc._body = as;
      rf.addStatement(sc);
      fastcast!(Module) (current_module()).entries ~= rf;
    }
  }
  // add interface refs
  void finalize() {
    fixupInterfaceAbstracts;
    genDefaultFuns;
    getClassinfo; // no-op to generate stuff
  }
  mixin TypeDefaults!();
  // interfaces come after the classinfo!
  int getFinalClassinfoLengthValue() {
    parseMe;
    int res = 1; // space for reflection data
    if (parent) res += parent.getVTable().length;
    res += myfuns.funs.length;
    // logln("for "[], name, "[], res is "[], res);
    return res;
  }
  LazyDeltaInt ownClassinfoLength() { // skipping interfaces
    return new LazyDeltaInt(&getFinalClassinfoLengthValue);
  }
  // array of function pointers
  string[] getVTable(LLVMFile lf = null, RelFunSet loverrides = Init!(RelFunSet)) { // local overrides
    parseMe;
    RelFunSet copy;
    copy.fillIn (loverrides);
    copy.fillIn (overrides);
    auto par = parent;
    while (par) {
      // use our parent's overriding functions to satisfy interfaces
      copy.fillIn (par.overrides);
      par = par.parent;
    }
    
    string[] res;
    // Liskov at work
    if (parent) res = parent.getVTable(lf, copy);
    
    foreach (fun; myfuns.funs) {
      if (auto f2 = copy.hasLike(fun)) // if a child class overrode this, use its relfun
        fun = f2;
      auto fmn = fun.mangleSelf();
      auto funtype = typeToLLVM(fun.getPointer().valueType());
      res ~= qformat("bitcast(", funtype, " @", fmn, " to i8*)");
      if (lf) lf.decls[fmn] = declare(fun, fmn);
    }
    
    // interfaces
    if (iparents.length) {
      string offset = offsetOfVTable();
      // string offset = classSize(false);
      offset = llAlign(offset, voidp);
      offset = lldiv(offset, voidp.llvmSize()); // steps of (void*).sizeof
      foreach (intf; iparents)
        res ~= intf.genVTable(offset, copy, lf);
    }
    
    return res;
  }
  
  string[] getClassinfo(LLVMFile lf = null) {
    string[] res;
    res ~= "@"~cd_name();
    res ~= getVTable(lf);
    return res;
  }
  string[] getClassinfoData(LLVMFile lf) {
    auto prefix = cd_name();
    string[] res;
    res ~= qformat("inttoptr(i32 ", this.name.length, " to i8*)");
    auto data = cast(ubyte[]) this.name~cast(ubyte) 0;
    res ~= datatollvm(lf, prefix~"_name", data);
    if (parent) {
      auto cd_name = parent.cd_name();
      res ~= "@"~cd_name;
      if (!(cd_name in lf.decls))
        lf.decls[cd_name] = qformat(res[$-1], " = external global i8");
    }
    else res ~= "inttoptr(i32 0 to i8*)";
    {
      string[] iplist;
      foreach (intf; iparents) {
        iplist ~= intf.getIntfinfoDataPtr(lf);
      }
      res ~= qformat("inttoptr(i32 ", iplist.length, " to i8*)");
      res ~= datatollvm(lf, prefix~"_iparents", iplist);
    }
    return res;
  }
  bool funAlreadyDefinedAbove(Function fun) {
    if (parent) parent.parseMe;
    if (parent && (
       parent.funAlreadyDefinedAbove(fun)
    || parent.myfuns.defines(fun))) return true;
    foreach (ipar; iparents) if (ipar.declares(fun.name)) return true;
    return false;
  }
  string classSize(bool withInterfaces) {
    parseMe;
    auto parentsize = parent?parent.classSize(true):"0";
    auto res = llmax(voidp.llvmSize(), parentsize, data.llvmSize());
    if (iparents.length) {
      if (!finalized) {
        if (withInterfaces) {
          getIntfLeaves((Intf) { res = lladd(res, voidp.llvmSize()); });
        }
      } else {
        if (!withInterfaces) {
          // interfaces are already included in the data
          // thus, we actually need to SUBTRACT them back out in this case
          // res = llAlign(res, voidp);
          // getIntfLeaves((Intf) { res = lladd(res, voidp.llvmSize()); });
          getIntfLeaves((Intf) { res = llsub(res, voidp.llvmSize()); });
        }
      }
    }
    // logln(name, " class size = ", res, " for data ", data.llvmType());
    return res;
  }
  // TODO
  mixin defaultIterate!();
  string vt_name() { return "vtable_"~mangle(); }
  string cd_name() { return "classdata_"~mangle(); }
  override {
    IType getRefType() {
      return fastalloc!(ClassRef)(this);
    }
    void emitLLVM(LLVMFile lf) {
      if (once(lf, "oop ", mangle())) {
        auto name = vt_name().dup;
        auto cd = cd_name().dup;
        lf.undecls[name] = true;
        lf.undecls[cd] = true;
        auto ci = getClassinfo(lf), cda = getClassinfoData(lf);
        string flags;
        // if (weak)
          flags ~= "weak_odr ";
        putSection(lf, "module", "@", name, ".full = "~flags~"global ", toLLVMArray(-1, ci));
        putSection(lf, "module", "@", cd  , ".full = "~flags~"global ", toLLVMArray(-1, cda));
        putSection(lf, "module", "@", name, " = alias "~flags~"i8* bitcast([", ci.length, " x i8*]* @", name, ".full to i8*)");
        putSection(lf, "module", "@", cd, " = alias "~flags~"i8* bitcast([", cda.length, " x i8*]* @", cd, ".full to i8*)");
      }
    }
    void _add(string name, Object obj) {
      assert(!finalized, "Adding "~name~" to already-finalized class. "[]);
      if (auto fun = fastcast!(Function) (obj)) fun.sup = this;
      if (auto rf = fastcast!(RelFunction) (obj)) {
        if (funAlreadyDefinedAbove(rf))
          overrides.add(name, rf);
        else {
          if (overridingFunctionState) {
            breakpoint();
            throw new Exception
              (qformat("tried to override function '", name, "' but could not find parent function to override"));
          }
          myfuns.funs ~= rf;
        }
      } else {
        data._add(name, obj);
      }
    }
    string mangle(string name, IType type) {
      string typemangle;
      if (type) typemangle = type.mangle();
      auto cleanname = name.cleanup();
      qappend("class_"[], cleanname, "_"[], name);
      if (type) {
        qappend("_of_"[], typemangle);
      }
      return qfinalize();
    }
    /*Stuple!(IType, string)[] stackframe() {
      parseMe;
      Stuple!(IType, string)[] res;
      if (parent) res = parent.stackframe();
      res ~= selectMap!(RelMember, "stuple($.type, $.name)"[]);
      return res;
    }*/
    Object lookupRel(string str, Expr base, bool isDirectLookup = true) {
      if (!base) {
        if (str == "__name"[]) // T.name
          return fastcast!(Object) (mkString(name));
        if (name == "__mangle"[])
          return fastcast!(Object) (mkString(mangle_id));
      }
      auto crType = fastcast!(ClassRef) (resolveType(base.valueType()));
      if (!crType) {
        logln("Bad class ref: "[], base, " of "[], base.valueType());
        fail;
      }
      if (str == "this"[]) return fastcast!(Object) (base);
      if (str == "super"[]) return fastcast!(Object) (reinterpret_cast(fastalloc!(SuperType)(crType), base));
      
      parseMe;
      
      if (auto res = data.lookup(str, true)) {
        if (auto rm = fastcast!(RelTransformable) (res)) {
          return rm.transform(fastalloc!(DerefExpr)(reinterpret_cast(fastalloc!(Pointer)(data), base)));
        }
        return fastcast!(Object)~ res;
      }
      Extensible ext;
      void extend(Extensible e) {
        if (ext) {
          if (auto os = fastcast!(OverloadSet) (ext)) {
            if (auto fun = fastcast!(Function) (e)) {
              foreach (fun2; os.funs) {
                if (fun.type == fun2.type) {
                  return; // already added
                }
              }
            }
          }
          if (auto fun = fastcast!(Function) (ext)) {
            if (auto fun2 = fastcast!(Function) (e)) {
              if (fun.type == fun2.type)
                return; // already added
            }
          }
          ext = ext.extend(e);
        } else {
          ext = e;
        }
      }
      if (auto res = myfuns.lookup(str, base)) {
        if (auto ext2 = fastcast!(Extensible) (res)) {
          extend(ext2);
        } else return res;
      }
      auto cl_offset = ownClassinfoLength();
      foreach (intf; iparents) {
        if (auto res = intf.lookupClass(str, cl_offset.dup, base)) {
          auto obj = fastcast!(Object) (res);
          if (auto ext2 = fastcast!(Extensible) (res)) {
            extend(ext2);
          } else return obj;
        }
        cl_offset.delta += intf.clsize;
      }
      delete cl_offset;
      if (parent) if (auto res = parent.lookupRel(str, base, isDirectLookup)) {
        if (auto ext2 = fastcast!(Extensible) (res)) {
          extend(ext2);
        } else return res;
      }
      return fastcast!(Object) (ext);
    }
    Object lookup(string id, bool local = false) {
      parseMe;
      if (id == "this") return fastalloc!(LazyThisExpr)(getRefType());
      if (auto res = data.lookup(id, local)) return res;
      if (local) return null;
      if (auto rn = fastcast!(RelNamespace) (sup)) {
        if (ctx) {
          auto bp = fastcast!(Expr) (namespace().lookup("__base_ptr"[], true));
          if (bp) {
            bp = fastalloc!(DerefExpr)(reinterpret_cast(fastalloc!(Pointer)(data), bp));
            // logln(bp);
            // logln("for "[], namespace(), ", "[], ctx);
            Object mew(Expr cref, RelNamespace rn) {
              // rn := Scope
              // cref := this.context := __base_ptr
              cref = ctxFixup(cref);
              if (auto res = rn.lookupRel(id, cref))
                return res;
              return null;
            }
            Expr cref = fastcast!(Expr) (ctx.transform(bp));
            while (true) {
              if (auto res = mew(cref, rn)) return res;
              if (auto cl = fastcast!(Class) (rn)) {
                if (!cl.ctx) break;
                cref = fastcast!(Expr) (cl.ctx.transform(fastalloc!(DerefExpr)(reinterpret_cast(fastalloc!(Pointer)(cl.data), cref))));
                rn = fastcast!(RelNamespace) (cl.sup);
                if (!rn) break;
                continue;
              }
              break;
            }
          }
        }/* else {
          logln("use regular lookup (into rn) for "[], id, " to "[], sup);
          logln(" => "[], sup.lookup(id, false));
        }*/
        return fastcast!(Namespace) (get!(Importer)).lookup(id, false);
      }
      return sup.lookup(id, false);
    }
  }
}

ClassRef parseClassBody(ref string text, ParseCb cont, ParseCb rest, string name, bool hadAbstract = false) {
  auto t2 = text;
  auto t3 = t2;
  string sup;
  Class cl, supclass;
  Intf[] supints;
  IType suptype;
  if (t3.accept(":"[]))
    if (!t3.bjoin(
      !!rest(t3, "type"[], &suptype),
      t3.accept(","[]),
      {
        t2 = t3;
        auto cr = fastcast!(ClassRef)  (suptype);
        auto ir = fastcast!(IntfRef) (suptype);
        if (!cr && !ir) throw new Exception("Cannot inherit from "~sup~": not a class or interface. "[]);
        if (ir) supints ~= ir.myIntf;
        else {
          if (ir) t3.failparse("Class must come first in inheritance spec"[]);
          if (supclass) t3.failparse("Multiple inheritance is not supported"[]);
          supclass = cr.myClass;
        }
      },
      false
  )) t3.failparse("Invalid inheritance spec"[]);
  New(cl, name, supclass);
  cl.declared_abstract = hadAbstract;
  cl.iparents = supints;
  
  auto classref = fastcast!(ClassRef) (cl.getRefType());
  namespace().add(classref);
  
  auto block = t2.coarseLexScope(true);
  
  cl.coarseSrc = block;
  cl.coarseCtx = namespace();
  cl.coarseMod = current_module();
  
  // cl.parseMe();
  
  text = t2;
  return classref;
}

// copypaste from ast/structure.d :(
Object gotClassDef(ref string text, ParseCb cont, ParseCb rest) {
  auto t2 = text;
  string name;
  bool isabstract;
  if (t2.accept("abstract"[])) isabstract = true;
  if (!t2.accept("class"[])) return null;
  if (!t2.gotIdentifier(name)) return null;
  if (auto res = parseClassBody(t2, cont, rest, name, isabstract)) {
    text = t2;
    return res;
  }
  t2.failparse("logic error"[]);
}
mixin DefaultParser!(gotClassDef, "tree.typedef.class"[]);
mixin DefaultParser!(gotClassDef, "struct_member.nested_class"[]);

Object gotClassDefStmt(ref string text, ParseCb cont, ParseCb rest) {
  if (!gotClassDef(text, cont, rest)) return null;
  return Single!(NoOp);
}
mixin DefaultParser!(gotClassDefStmt, "tree.stmt.class"[], "312"[]);

int anonclasscounter;

Object gotAnonymousClassType(ref string text, ParseCb cont, ParseCb rest) {
  auto t2 = text;
  bool isabstract;
  if (t2.accept("abstract"[])) isabstract = true;
  if (!t2.accept("class"[])) return null;
  if (t2.accept("-"[])) return null; // class-stuff
  string bogus;
  if (t2.gotIdentifier(bogus)) return null; // NON-anonymous class!
  if (isabstract)
    text.failparse("Anonymous classes must not be abstract"[]);
  string name;
  synchronized name = qformat("_anonymous_class_"[], anonclasscounter ++);
  if (auto res = parseClassBody(t2, cont, rest, name, false)) {
    text = t2;
    return res;
  }
  t2.failparse("logic error"[]);
}
mixin DefaultParser!(gotAnonymousClassType, "type.anonclass"[], "7"[]);

Object gotIntfDef(ref string text, ParseCb cont, ParseCb rest) {
  auto t2 = text;
  string name;
  if (!t2.gotIdentifier(name)) return null;
  auto t3 = t2;
  Intf[] supints;
  if (t3.accept(":"[])) {
    string sup;
    if (!t3.bjoin(
      t3.gotIdentifier(sup),
      t3.accept(","[]),
      {
        t2 = t3;
        auto supobj = namespace().lookup(sup);
        auto intf = fastcast!(IntfRef) (supobj);
        if (!intf) throw new Exception("Cannot inherit interface '"~name~"' from "~sup~": not an interface: "~Format(supobj));
        else supints ~= intf.myIntf;
      },
      false
    )) t3.failparse("Invalid interface inheritance spec"[]);
  }
  bool predecl;
  if (!t2.accept("{"[]) && !(t2.accept(";"[]) && (predecl = true, true))) t2.failparse("Missing opening bracket for class def"[]);
  auto intf = fastalloc!(Intf)(name);
  intf.sup = namespace();
  intf.parents = supints;
  intf.initOffset;
  intf.predecl = predecl;
  auto backup = namespace();
  scope(exit) namespace.set(backup);
  namespace.set(intf);
  bool reuse;
  if (!predecl) {
    auto pref = fastcast!(IntfRef) (backup.lookup(name));
    if (pref && pref.myIntf.predecl) { intf = pref.myIntf; reuse = true; }
  }
  if (!reuse)
    backup.add(intf.getRefType()); // support interface A { A foo(); }
  if (predecl) { text = t2; return intf.getRefType(); }
  while (true) {
    auto fun = new NestedFunction(intf);
    if (t2.accept("}"[])) break;
    Object obj;
    if (gotGenericFunDecl(fun, cast(Namespace) null, false, t2, cont, rest)) {
      intf.funs ~= fun;
    } else if (rest(t2, "struct_member.struct_alias"[], &obj)) {
      // already added
      assert(fastcast!(NamedNull) (obj));
    } else
      t2.failparse("Error parsing interface"[]);
    
  }
  text = t2;
  return intf.getRefType();
}
mixin DefaultParser!(gotIntfDef, "tree.typedef.intf"[], null, "interface"[]);

import ast.casting, ast.opers;

alias Single!(Pointer, Single!(Pointer, Single!(Void))) voidpp;

Expr intfToClass(Expr ex) {
  auto intpp = Single!(Pointer, Single!(Pointer, Single!(SysInt)));
  return reinterpret_cast(fastcast!(IType) (sysmod.lookup("Object"[])), lookupOp("+"[], reinterpret_cast(voidpp, ex), fastalloc!(DerefExpr)(fastalloc!(DerefExpr)(reinterpret_cast(intpp, ex)))));
}

void doImplicitClassCast(Expr ex, IType target, void delegate(Expr) dg) {
  void testIntf(Expr ex) {
    dg(ex);
    auto intf = (fastcast!(IntfRef)~ ex.valueType()).myIntf;
    int offs = 0;
    foreach (id, par; intf.parents) {
      auto nex = reinterpret_cast_safe(fastalloc!(IntfRef)(par), lookupOp("+"[], reinterpret_cast(voidpp, ex), mkInt(offs)));
      par.getLeaves((Intf) { offs++; });
      testIntf(nex);
    }
  }
  void testClass(Expr ex) {
    dg(ex);
    auto cl = (fastcast!(ClassRef) (ex.valueType())).myClass;
    if (!cl.parent && !cl.iparents) return; // just to clarify
    if (cl.parent) {
      testClass(reinterpret_cast_safe(cl.parent.getRefType(), ex));
    }
    // string offs = cl.classSize(false);
    string offs = cl.offsetOfVTable();
    offs = llAlign(offs, voidp);
    offs = lldiv(offs, "4");
    foreach (id, par; cl.iparents) {
      auto iex = reinterpret_cast_safe(fastalloc!(IntfRef)(par), lookupOp("+"[], reinterpret_cast(voidpp, ex), llvmval(offs)));
      par.getLeaves((Intf) { offs = lladd(offs, "1"); });
      testIntf(iex);
    }
  }
  auto cr = fastcast!(ClassRef)(ex.valueType()), ir = fastcast!(IntfRef)(ex.valueType());
  if (!cr && !ir) return;
  if (target) {
    auto crt = fastcast!(ClassRef)(target), irt = fastcast!(IntfRef)(target);
    if (!crt && !irt) return;
  }
  if (cr) testClass(ex);
  if (ir) testIntf(ex);
}

import ast.casting, ast.fold, tools.base: todg;
static this() {
  implicits ~= delegate Expr(Expr ex) {
    if (fastcast!(IntfRef)~ ex.valueType())
      return intfToClass(ex);
    return null;
  };
  implicits ~= &doImplicitClassCast /todg;
  converts ~= delegate Expr(Expr ex, IType dest) {
    if (!fastcast!(ClassRef) (resolveType(dest)) && !fastcast!(IntfRef) (resolveType(dest)))
      return null;
    if (!gotImplicitCast(ex, delegate bool(IType it) {
      return fastcast!(ClassRef) (resolveType(it)) || fastcast!(IntfRef) (resolveType(it));
    }))
      return null;
    string dest_id;
    if (auto cr = fastcast!(ClassRef) (resolveType(dest))) dest_id = cr.myClass.mangle_id;
    else dest_id = (fastcast!(IntfRef) (resolveType(dest))).myIntf.mangle_id;
    
    bool isIntf;
    if (fastcast!(IntfRef) (resolveType(ex.valueType()))) isIntf = true;
    ex = reinterpret_cast(voidp, ex);
    return iparse!(Expr, "cast_call"[], "tree.expr"[])
      ("Dest:_fcc_dynamic_cast(ex, id, isIntf)"[],
        "ex"[], ex, "Dest"[], dest, "id"[], mkString(dest_id), "isIntf"[], mkInt(isIntf)
      );
  };
}
