import gleam/json
import gleam/package_interface
import gleam/string
import shellout
import simplifile
import snag

pub fn build_js(root) {
  let result =
    shellout.command(
      run: "gleam",
      with: ["build", "--target=javascript"],
      in: root,
      opt: [],
    )
  case result {
    Ok(_) -> {
      let dir = string.append(root, "/build/dev/javascript")
      Ok(dir)
    }
    Error(_reason) -> snag.error("failed to bundle javascript")
  }
}

pub fn package_interface(root, package) {
  let filename =
    string.concat([root, "/build/dev/docs/", package, "/package-interface.json"])
  let assert Ok(content) = simplifile.read(filename)
  let assert Ok(interface) =
    json.decode(content, using: package_interface.decoder)
  Ok(interface)
}
