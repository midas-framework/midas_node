import filepath
import gleam/fetch
import gleam/http
import gleam/io
import gleam/javascript/promise
import gleam/result
import gleam/string
import gleam/uri
import glen
import glen/status
import glen_node
import midas/js/run as r
import midas/node/browser
import midas/node/file_system as fs
import midas/node/gleam
import midas/node/rollup
import midas/node/zip
import midas/task as t
import snag

pub fn run(task, root) {
  case task {
    t.Done(value) -> promise.resolve(Ok(value))
    t.Abort(reason) -> promise.resolve(Error(reason))
    t.Bundle(module, function, resume) -> {
      use project <- r.try(fs.current_directory())
      use js_dir <- r.try(gleam.build_js(project))
      // let assert Ok(#(package, _)) = string.split_once(module, "/")
      // Assumes that the package and module share name at top level
      let package = "eyg"
      let module_path = string.concat([package, "/", module])

      use bundle <- promise.await(rollup.bundle_fn(
        js_dir,
        module_path,
        function,
      ))
      let bundle = result.map_error(bundle, snag.pretty_print)
      run(resume(bundle), root)
    }
    t.Fetch(request, resume) -> {
      use return <- promise.await(do_fetch(request))
      run(resume(return), root)
    }
    t.Follow(uri, resume) -> {
      use return <- promise.await(do_follow(uri))
      let assert Ok(raw) = return
      run(resume(uri.parse(raw)), root)
    }
    t.List(directory, resume) -> {
      let path = filepath.join(root, directory)
      run(
        resume(fs.read_directory(path) |> result.map_error(snag.pretty_print)),
        root,
      )
    }
    t.Log(message, resume) -> {
      io.println(message)
      run(resume(Ok(Nil)), root)
    }
    t.Read(file, resume) -> {
      let path = filepath.join(root, file)
      let result = fs.read(path) |> result.map_error(snag.line_print)
      run(resume(result), root)
    }
    t.Write(file, bytes, resume) -> {
      let path = filepath.join(root, file)
      let result = fs.write(path, bytes) |> result.map_error(snag.line_print)
      run(resume(result), root)
    }
    t.Zip(files, resume) -> {
      use return <- promise.await(zip.zip(files))
      run(resume(Ok(return)), root)
    }
  }
}

pub fn do_fetch(request) {
  use response <- promise.await(fetch.send_bits(request))
  let assert Ok(response) = response
  use response <- promise.await(fetch.read_bytes_body(response))
  let response = case response {
    Ok(response) -> Ok(response)
    Error(fetch.NetworkError(s)) -> Error(t.NetworkError(s))
    Error(fetch.UnableToReadBody) -> Error(t.UnableToReadBody)
    Error(fetch.InvalidJsonBody) -> panic
  }
  promise.resolve(response)
}

fn do_follow(url) {
  browser.open(url)
  receive_redirect()
}

fn handle_redirect(request: glen.Request, resolve) {
  case request.method {
    http.Get ->
      "<html><body><h1>finalising authorization</h1><script>fetch(\"/\", {method:\"POST\",body:location})</script></body></html>"
      |> glen.html(status.ok)
      |> promise.resolve
    http.Post -> {
      use body <- promise.await(glen.read_text_body(request))
      case body {
        Ok(body) -> {
          resolve(body)
          ""
          // Post should return no content 201 but this crashes glen
          |> glen.html(status.ok)
          |> promise.resolve
        }
        Error(_) ->
          "Not text content"
          |> glen.html(status.bad_request)
          |> promise.resolve
      }
    }
    _ -> panic as "unexpected method"
  }
}

fn receive_redirect() {
  let #(promise, resolve) = promise.start()
  case glen_node.serve(8080, handle_redirect(_, resolve)) {
    Ok(server) -> {
      use url <- promise.await(promise)
      use Nil <- promise.await(glen_node.close(server))
      promise.resolve(Ok(url))
    }
    Error(reason) -> promise.resolve(Error(reason))
  }
}
