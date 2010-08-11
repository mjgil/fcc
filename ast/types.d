module ast.types;

import tools.base: Stuple, take;

interface IType {
  int size();
  string mangle();
  ubyte[] initval();
  int opEquals(Object obj);
}

template TypeDefaults(bool INITVAL = true, bool OPEQUALS = true) {
  static if (INITVAL) ubyte[] initval() { return new ubyte[size()]; }
  static if (OPEQUALS) int opEquals(Object obj) {
    // specialize where needed
    return this.classinfo is obj.classinfo &&
      size == (cast(typeof(this)) cast(void*) obj).size;
  }
}

class Type : IType {
  mixin TypeDefaults!();
  abstract int size();
  abstract string mangle();
}

class Void : Type {
  override int size() { return 1; } // for arrays
  override string mangle() { return "void"; }
  override ubyte[] initval() { return null; }
}

class Variadic : Type {
  override int size() { assert(false); }
  /// BAH
  // TODO: redesign parameter match system to account for automatic conversions in variadics.
  override string mangle() { return "variadic"; }
  override ubyte[] initval() { assert(false, "Cannot declare variadic variable. "); } // wtf variadic variable?
}

class Char : Type {
  override int size() { return 1; }
  override string mangle() { return "char"; }
}

const nativeIntSize = 4, nativePtrSize = 4;

class SizeT : Type {
  override int size() { return nativeIntSize; }
  override string mangle() { return "size_t"; }
}

class Short : Type {
  override int size() { return 2; }
  override string mangle() { return "short"; }
}

class SysInt : Type {
  override int size() { return nativeIntSize; }
  override string mangle() { return "sys_int"; }
}

// quick and dirty singleton
template _Single(T, U...) {
  T value;
  static this() { value = new T(U); }
}

template Single(T, U...) {
  static assert(is(T: Object));
  alias _Single!(T, U).value Single;
}

import parseBase;
Object gotBasicType(ref string text, ParseCb cont, ParseCb rest) {
  if (text.accept("void")) return Single!(Void);
  if (text.accept("size_t")) return Single!(SizeT);
  if (text.accept("int")) return Single!(SysInt);
  if (text.accept("short")) return Single!(Short);
  if (text.accept("char")) return Single!(Char);
  return null;
}
mixin DefaultParser!(gotBasicType, "type.basic", "5");

import tools.log;
Object gotVariadic(ref string text, ParseCb cont, ParseCb rest) {
  if (text.accept("...")) return Single!(Variadic);
  return null;
}
mixin DefaultParser!(gotVariadic, "type.variadic", "9");

// postfix type modifiers
IType delegate(ref string text, IType cur, ParseCb cont, ParseCb rest)[]
  typeModlist;

Object gotExtType(ref string text, ParseCb cont, ParseCb rest) {
  auto type = cast(IType) cont(text);
  if (!type) return null;
  restart:
  foreach (dg; typeModlist) {
    if (auto nt = dg(text, type, cont, rest)) {
      type = nt;
      goto restart;
    }
  }
  return cast(Object) type;
}
mixin DefaultParser!(gotExtType, "type.ext", "1");
