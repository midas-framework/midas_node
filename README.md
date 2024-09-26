# midas_node

[![Package Version](https://img.shields.io/hexpm/v/midas_node)](https://hex.pm/packages/midas_node)
[![Hex Docs](https://img.shields.io/badge/hex-docs-ffaff3)](https://hexdocs.pm/midas_node/)



```sh
npm install --save @zip.js/zip.js rollup @rollup/plugin-node-resolve
gleam add midas_node
```

```gleam
import midas/node

pub fn main() {
  let task = // a midas task
  node.run(task, "/root")
}
```

Further documentation can be found at <https://hexdocs.pm/midas_node>.

## Development

```sh
gleam run   # Run the project
gleam test  # Run the tests
```
