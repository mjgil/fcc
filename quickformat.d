module quickformat;

import tools.threads, tools.base;
import casts;

extern(C) Stuple!(string, int)* get_qbuffer_ptr();

void qbuffer_resize_internal(int i, string* qbufferp, int* offsp) {
  if ((*qbufferp).length < i) {
    auto backup = (*qbufferp);
    // there's no chance to free this anyway, so don't let the gc bother with it
    // otherwise the get_qbuffer_ptr will fail because we keep reference in C space
    // (*qbufferp) = new char[max(65536, i)];
    (*qbufferp) = (cast(char*) std.c.stdlib.malloc(max(65536, i)))[0..65536];
    (*qbufferp)[0 .. backup.length] = backup;
  }
}

void qappend(string[] args...) {
  auto qp = get_qbuffer_ptr();
  string qbuffer; int offs;
  ptuple(qbuffer, offs) = *qp;
  
  int total_len;
  foreach (arg; args) total_len += arg.length;
  qbuffer_resize_internal(offs + total_len, &qbuffer, &offs);
  
  foreach (arg; args) {
    qbuffer[offs .. offs + arg.length] = arg;
    offs += arg.length;
  }
  
  *qp = stuple(qbuffer, offs);
}

void qformat_append(T...)(T t) {
  foreach (entry; t) {
    static if (is(typeof(entry): string)) {
      qappend(entry);
    }
    else static if (is(typeof(entry): ulong)) {
      auto num = entry;
      if (!num) { qappend("0"[]); continue; }
      if (num == -0x8000_0000) { qappend("-2147483648"[]); }
      else {
        if (num < 0) { qappend("-"[]); num = -num; }
        
        // gotta do this left to right!
        static if (typeof(num).sizeof == 4) alias int IntType;
        else static if (typeof(num).sizeof == 8) alias long IntType;
        else static if (typeof(num).sizeof == 2) alias short IntType;
        else static if (typeof(num).sizeof == 1) alias byte IntType;
        else static assert(false, typeof(num).stringof);
        IntType ifact = 1;
        while (ifact <= num / 10) ifact *= 10;
        while (ifact) {
          int inum = num / ifact;
          char[1] ch;
          ch[0] = "0123456789"[inum];
          qappend(ch);
          num -= cast(long) inum * cast(long) ifact;
          ifact /= 10L;
        }
      }
    }
    else static if (is(typeof(entry[0]))) {
      qappend("["[]);
      bool first = true;
      foreach (element; entry) {
        if (first) first = false;
        else qappend(", "[]);
        qformat_append(element);
      }
      qappend("]"[]);
    }
    else static if (is(typeof(fastcast!(Object) (entry)))) {
      auto obj = fastcast!(Object) (entry);
      if (obj) qappend(obj.toString());
      else { qappend(typeof(entry).stringof); qappend(":null"); }
    }
    else static assert(false, "not supported in qformat: "~typeof(entry).stringof);
  }
}

string qfinalize() {
  auto qp = get_qbuffer_ptr();
  string qbuffer; int offs;
  ptuple(qbuffer, offs) = *qp;
  auto res = qbuffer[0 .. offs];
  qbuffer = qbuffer[offs .. $];
  *qp = stuple(qbuffer, 0);
  return res;
}

string qformat(T...)(T t) {
  qformat_append(t);
  return qfinalize();
}

string qjoin(string[] args) {
  foreach (arg; args)
    qappend(arg);
  return qfinalize();
}
