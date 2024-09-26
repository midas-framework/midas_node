import gleam/javascript/promise.{type Promise}

@external(javascript, "../midas_promisex_ffi.mjs", "start")
pub fn start() -> #(Promise(a), fn(a) -> Nil)
