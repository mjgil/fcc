module test14;
import std.string;

void main() {
  mixin `writeln "Hello World"`;
  mixin `writeln "Hello` ~ ` World 2"`;
  mixin `writeln "Hello %"`.replace("%", "World 3");
}
