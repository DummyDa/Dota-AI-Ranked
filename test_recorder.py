from pathlib import Path
import unittest
from lupa.lua54 import LuaRuntime

ROOT = Path(__file__).resolve().parent

class RecorderSafetyTest(unittest.TestCase):
    def test_no_autonomous_orders(self):
        lua = LuaRuntime(unpack_returned_tuples=True)
        lua.execute((ROOT / 'tests/mock_umbrella.lua').read_text(encoding='utf-8'))
        lua.execute('Chat={Print=function() end}; _G=nil; os=nil; io=nil; debug=nil')
        script = lua.execute((ROOT / 'spirit_breaker_recorder.lua').read_text(encoding='utf-8'))
        for _ in range(5):
            script.OnUpdate()
        lua.execute('assert(#orders==0); local ok,err=DotaAI.Command("MOVE_TO", {}, 5); assert(ok==false and err=="record_only"); assert(#orders==0)')

    def test_record_only_update_and_flush(self):
        source = (ROOT / 'spirit_breaker_recorder.lua').read_text(encoding='utf-8')
        update = source.split('function script.OnUpdate()', 1)[1].split('function script.OnDraw()', 1)[0]
        self.assertNotIn('Player.', update)
        self.assertNotIn('update_external_action', update)
        self.assertIn('recording_enabled or #bridge.manual_orders > 0', source)
        setter = source.split('local function set_recording_mode', 1)[1].split('local function update_button', 1)[0]
        self.assertNotIn('bridge.manual_orders = {}', setter)
        self.assertIn('held_right_interval = 0.20', source)

if __name__ == '__main__':
    unittest.main()
