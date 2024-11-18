import gleam/io
import gleam/option.{Some}
import midas/node
import midas/task as t
import snag

pub fn example() {
  todo
}

fn build() {
  use src <- t.do(t.bundle("example/client", "run"))
  use page <- t.do(t.read("src/index.html"))
  t.done([#("/", page), #("/main.js", <<src:utf8>>)])
}

fn preview() {
  use content <- t.do(build())
  t.serve_static(Some(8080), content)
}

pub fn main() {
  node.watch(preview(), ".", callback)
}

fn callback(result) {
  case result {
    Ok(Nil) -> Nil
    Error(reason) -> io.println(snag.pretty_print(reason))
  }
}
