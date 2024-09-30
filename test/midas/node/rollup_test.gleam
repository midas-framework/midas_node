import gleam/javascript/promise
import gleam/string
import gleeunit/should
import midas/node/rollup
import simplifile

pub fn iife_test() {
  let assert Ok(cwd) = simplifile.current_directory()
  let entry = string.append(cwd, "/test/midas/node/rollup/main.js")
  use code <- promise.map(rollup.iife(entry))
  should.be_ok(code)
  |> string.contains("function add")
  |> should.be_true
}
