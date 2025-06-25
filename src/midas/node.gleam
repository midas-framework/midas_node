import filepath
import gleam/crypto
import gleam/fetch
import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/io
import gleam/javascript/promise
import gleam/list
import gleam/option
import gleam/result
import gleam/string
import gleam/uri
import glen
import glen/status
import glen_node
import javascript/mutable_reference
import midas/js/run as r
import midas/node/browser
import midas/node/chokidar
import midas/node/file_system as fs
import midas/node/gleam
import midas/node/rollup
import midas/node/zip
import midas/task as t
import plinth/browser/crypto/subtle
import plinth/javascript/date
import snag.{type Snag}

// currently this is not smart as all projects are small enough to rely on chokidar to effeciently watch files.
fn sources(_previous) {
  ["./src"]
}

// I think it might be worth in the future keeping servers to stop outside the cache of effects.
fn stop_servers(servers) {
  case servers {
    [] -> promise.resolve(Nil)
    [#(_port, server), ..previous] -> {
      use Nil <- promise.await(glen_node.close(server))
      stop_servers(previous)
    }
  }
}

type Coordinator(a, c) {
  Working(changed: List(String))
  Ready(
    root: String,
    callback: fn(Result(a, Snag)) -> Nil,
    final: Result(a, Snag),
    previous: List(t.Effect(a, c)),
    servers: List(#(Int, glen_node.Server)),
  )
}

fn redo(final, previous, servers, root, invalidated, unchanged) {
  let src_affected = list.any(invalidated, string.starts_with(_, "src"))

  case previous {
    [] -> promise.resolve(#(final, list.reverse(unchanged), []))
    [cached, ..previous] -> {
      let unchanged = [cached, ..unchanged]
      case cached {
        t.Bundle(mod, func, resume) if src_affected -> {
          use Nil <- promise.await(stop_servers(servers))
          use output <- promise.await(do_bundle(mod, func))
          let output = result.map_error(output, snag.pretty_print)
          do_run(resume(output), root, unchanged, servers)
        }
        t.Read(file, resume) -> {
          case list.contains(invalidated, file) {
            True -> {
              use Nil <- promise.await(stop_servers(servers))
              do_run(resume(do_read(file, root)), root, unchanged, servers)
            }
            False ->
              redo(final, previous, servers, root, invalidated, unchanged)
          }
        }
        t.Serve(port, _handle, _resume) -> {
          let servers = case list.key_pop(servers, option.unwrap(port, 8080)) {
            Ok(#(_, servers)) -> servers
            Error(Nil) -> servers
          }
          redo(final, previous, servers, root, invalidated, unchanged)
        }
        _ -> redo(final, previous, servers, root, invalidated, unchanged)
      }
    }
  }
}

type Message(a, c) {
  WatchMessage(chokidar.AllEvent, String)
  Done(
    root: String,
    callback: fn(Result(a, Snag)) -> Nil,
    final: Result(a, Snag),
    previous: List(t.Effect(a, c)),
    servers: List(#(Int, glen_node.Server)),
  )
}

fn handle(self, message, state) {
  case state {
    Ready(root, callback, final, previous, servers) ->
      case message {
        WatchMessage(chokidar.Change, path) -> {
          promise.map(
            redo(final, previous, servers, root, [path], []),
            fn(result) {
              let #(final, previous, servers) = result
              callback(final)
              send(self, Done(root, callback, final, previous, servers))
            },
          )
          Working([])
        }
        WatchMessage(_, _path) -> state
        Done(..) -> {
          io.println("should not happen")
          state
        }
      }
    Working(changed) -> {
      case message {
        WatchMessage(chokidar.Change, path) -> {
          Working([path, ..changed])
        }
        WatchMessage(_, _path) -> state
        Done(root, callback, final, previous, servers) ->
          Ready(root, callback, final, previous, servers)
      }
    }
  }
}

fn send(ref, message) {
  mutable_reference.update(ref, handle(ref, message, _))
  Nil
}

pub fn watch(task, root, callback) {
  use #(final, previous, servers) <- promise.await(do_run(task, root, [], []))
  let initial = sources(previous)
  let watcher = chokidar.watch(initial)

  let ref =
    mutable_reference.new(Ready(root, callback, final, previous, servers))
  callback(final)
  chokidar.on_all(watcher, fn(event, path) {
    send(ref, WatchMessage(event, path))
  })
  promise.resolve(Nil)
}

pub fn run(task, root) {
  use #(result, _cache, _servers) <- promise.map(do_run(task, root, [], []))
  result
}

fn do_run(task, root, cache, servers) {
  case task {
    t.Done(value) -> promise.resolve(#(Ok(value), list.reverse(cache), servers))
    t.Abort(reason) ->
      promise.resolve(#(Error(reason), list.reverse(cache), servers))
    t.Bundle(module, function, resume) -> {
      use output <- promise.await(do_bundle(module, function))
      let output = result.map_error(output, snag.pretty_print)
      let cache = [task, ..cache]
      do_run(resume(output), root, cache, servers)
    }
    t.ExportJsonWebKey(key, resume) -> {
      use output <- promise.await(subtle.export_jwk(key))
      let cache = [task, ..cache]
      do_run(resume(output), root, cache, servers)
    }
    t.Fetch(request, resume) -> {
      use return <- promise.await(do_fetch(request))
      let cache = [task, ..cache]
      do_run(resume(return), root, cache, servers)
    }
    t.Follow(uri, resume) -> {
      use return <- promise.await(do_follow(uri))
      let assert Ok(raw) = return
      let cache = [task, ..cache]
      do_run(resume(uri.parse(raw)), root, cache, servers)
    }
    t.GenerateKeyPair(algorithm, exportable, usages, resume) -> {
      let alg = case algorithm {
        t.EcKeyGenParams(name, curve) -> subtle.EcKeyGenParams(name, curve)
      }
      let usages = list.map(usages, usage_to_subtle)
      use result <- promise.await(subtle.generate_key(alg, exportable, usages))
      let result = case result {
        Ok(#(public, private)) -> Ok(t.KeyPair(public:, private:))
        Error(reason) -> Error(reason)
      }
      let cache = [task, ..cache]
      do_run(resume(result), root, cache, servers)
    }
    t.Hash(algorithm, bytes, resume) -> {
      use result <- promise.await(do_hash(algorithm, bytes))
      let cache = [task, ..cache]
      do_run(resume(result), root, cache, servers)
    }
    t.List(directory, resume) -> {
      let path = filepath.join(root, directory)
      let entries = fs.read_directory(path)
      let entries = result.map_error(entries, snag.pretty_print)
      let cache = [task, ..cache]
      do_run(resume(entries), root, cache, servers)
    }
    t.Log(message, resume) -> {
      io.println(message)
      let cache = [task, ..cache]
      do_run(resume(Ok(Nil)), root, cache, servers)
    }
    t.Read(file, resume) -> {
      let cache = [task, ..cache]
      do_run(resume(do_read(file, root)), root, cache, servers)
    }
    t.Serve(port, handle, resume) -> {
      let port = option.unwrap(port, 8080)
      let #(result, servers) = case do_serve(port, handle) {
        Ok(server) -> #(Ok(Nil), [#(port, server), ..servers])
        Error(reason) -> #(Error(reason), servers)
      }
      let cache = [task, ..cache]
      do_run(resume(result), root, cache, servers)
    }
    t.Sign(algorithm, key, data, resume) -> {
      let algorithm = case algorithm {
        t.EcdsaParams(x) -> subtle.EcdsaParams(hash_algorithm_to_subtle(x))
      }
      use result <- promise.await(subtle.sign(algorithm, key, data))
      let cache = [task, ..cache]
      do_run(resume(result), root, cache, servers)
    }
    t.StrongRandom(length, resume) -> {
      let bytes = crypto.strong_random_bytes(length)
      let cache = [task, ..cache]
      do_run(resume(Ok(bytes)), root, cache, servers)
    }
    t.UnixNow(resume) -> {
      let now = date.get_time(date.now()) / 1000
      let cache = [task, ..cache]
      do_run(resume(now), root, cache, servers)
    }
    t.Visit(uri, resume) -> {
      browser.open(uri.to_string(uri))
      let cache = [task, ..cache]
      do_run(resume(Ok(Nil)), root, cache, servers)
    }
    t.Write(file, bytes, resume) -> {
      let path = filepath.join(root, file)
      let result = fs.write(path, bytes) |> result.map_error(snag.line_print)
      let cache = [task, ..cache]
      do_run(resume(result), root, cache, servers)
    }
    t.Zip(files, resume) -> {
      use return <- promise.await(zip.zip(files))
      let cache = [task, ..cache]
      do_run(resume(Ok(return)), root, cache, servers)
    }
  }
}

pub fn do_bundle(module, function) {
  use project <- r.try(fs.current_directory())
  use js_dir <- r.try(gleam.build_js(project))
  let package = case string.split_once(module, "/") {
    Ok(#(package, _)) -> package
    Error(Nil) -> module
  }
  // Assumes that the package and module share name at top level
  // let package = "eyg"
  let module_path = string.concat([package, "/", module])

  rollup.bundle_fn(js_dir, module_path, function)
}

pub fn do_fetch(request) {
  use response <- promise.await(fetch.send_bits(request))
  case response {
    Error(reason) -> promise.resolve(Error(cast_fetch_error(reason)))
    Ok(response) -> {
      use response <- promise.await(fetch.read_bytes_body(response))
      let response = case response {
        Ok(response) -> Ok(response)
        Error(reason) -> Error(cast_fetch_error(reason))
      }
      promise.resolve(response)
    }
  }
}

fn cast_fetch_error(reason) {
  case reason {
    fetch.NetworkError(s) -> t.NetworkError(s)
    fetch.UnableToReadBody -> t.UnableToReadBody
    fetch.InvalidJsonBody -> t.UnableToReadBody
  }
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
    http.Options ->
      ""
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
    m -> panic as { "unexpected method" <> http.method_to_string(m) }
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

fn do_hash(algorithm, bytes) {
  let algorithm = hash_algorithm_to_subtle(algorithm)
  subtle.digest(algorithm, bytes)
}

fn hash_algorithm_to_subtle(algorithm) {
  case algorithm {
    t.SHA1 -> subtle.SHA1
    t.SHA256 -> subtle.SHA256
    t.SHA384 -> subtle.SHA384
    t.SHA512 -> subtle.SHA512
  }
}

fn usage_to_subtle(usage) {
  case usage {
    t.CanEncrypt -> subtle.Encrypt
    t.CanDecrypt -> subtle.Decrypt
    t.CanSign -> subtle.Sign
    t.CanVerify -> subtle.Verify
    t.CanDeriveKey -> subtle.DeriveKey
    t.CanDeriveBits -> subtle.DeriveBits
    t.CanWrapKey -> subtle.WrapKey
    t.CanUnwrapKey -> subtle.UnwrapKey
  }
}

fn do_read(file, root) {
  let path = filepath.join(root, file)
  fs.read(path) |> result.map_error(snag.line_print)
}

fn do_serve(port, handle) {
  glen_node.serve(port, fn(request) {
    use body <- promise.map(glen.read_body_bits(request))
    case body {
      Ok(body) -> {
        let request = request.set_body(request, body)
        let response = handle(request)
        response
        |> response.set_body(glen.Bits(response.body))
      }
      Error(_reason) ->
        response.new(500)
        |> response.set_body(glen.Bits(<<"failed to read request body">>))
    }
  })
}
