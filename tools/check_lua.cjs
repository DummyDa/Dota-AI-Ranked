const fs = require('fs');
const path = require('path');
const root = path.resolve(__dirname, '..');
let parser;
try { parser = require('luaparse'); }
catch (err) {
  const cache = path.join(root, '.npm-cache-lua', '_npx');
  for (const entry of fs.existsSync(cache) ? fs.readdirSync(cache) : []) {
    try { parser = require(path.join(cache, entry, 'node_modules', 'luaparse')); break; } catch (_) {}
  }
  if (!parser) throw new Error('Run npm install --ignore-scripts to install the development Lua parser');
}
for (const file of process.argv.slice(2)) {
  parser.parse(fs.readFileSync(file, 'utf8'), {luaVersion: '5.3'});
  console.log('Lua parse OK: ' + path.basename(file));
}
