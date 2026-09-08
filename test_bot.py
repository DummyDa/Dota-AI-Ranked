"""Executable Lua contract/scenario tests; do not claim actual Dota match coverage."""
from pathlib import Path
import unittest
from lupa.lua54 import LuaRuntime
from build_bot import MODULES, ROOT, bundle

class BotTest(unittest.TestCase):
    def setUp(self):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.lua.execute((ROOT / 'tests/mock_umbrella.lua').read_text(encoding='utf-8'))
        self.lua.execute('_G=nil; os=nil; io=nil; debug=nil')
        self.lua.execute('B={}')
        for name in MODULES:
            init = self.lua.execute((ROOT / 'src' / f'{name}.lua').read_text(encoding='utf-8'))
            init(self.lua.globals().B)

    def check(self, code):
        self.lua.execute(code)

    def test_default_autonomous_no_http(self):
        self.check('B.script.OnUpdate(); assert(B.enabled); assert(B.state); assert(not B.error); assert(not B.config.bridgeEnabled); assert(not B.config.externalEnabled)')

    def test_role_radiant_dire(self):
        self.check('''for _,team in ipairs({2,3}) do for _,flags in ipairs({8,16,0,24}) do
            hero.team=team; core.team=team; hero.roleFlags=flags
            local s=B.adapter.refresh(); local role=flags==8 and 4 or 5
            assert(s.role==role); assert(s.lane==(((team==2)==(role==5)) and 'bot' or 'top'))
        end end''')

    def test_other_hero_never_controlled(self):
        self.check("hero.name='npc_dota_hero_sniper'; B.script.OnUpdate(); assert(#orders==0); assert(B.state==nil)")

    def test_hidden_enemy_excluded_before_position_read(self):
        self.check("local e=unit(3,'npc_dota_hero_riki',3,10,10); e.visible=false; world[#world+1]=e; local s=B.adapter.refresh(); assert(#s.enemies==0 and not s.byIndex[3])")

    def test_role_core_selection(self):
        self.check("local s=B.adapter.refresh(); assert(s.core.index==core.index); assert(s.hero.abilityPoints==0)")

    def test_lane_path_from_base(self):
        self.check("local s=B.adapter.refresh(); local m=B.arbiter.choose(s); assert(m.name=='lane' or m.name=='patrol',m.name); local i=B.arbiter.intent(s,m); assert(i.kind=='move'); assert(B.executor.execute(s,i))")

    def test_tower_emergency(self):
        self.check("local t=unit(4,'npc_dota_badguys_tower1_mid',3,-6200,-6200); t.range=700; t.target=hero; world[#world+1]=t; local s=B.adapter.refresh(); local m=B.threat.safety(s); assert(m and m.name=='SAFETY'); assert(B.dist(m.pos,t.pos)>B.dist(s.hero.pos,t.pos))")

    def test_early_creep_aggro(self):
        self.check("local s=B.adapter.refresh(); s.hero.recentDamage=100; for i=1,3 do local c=B.adapter.unit(unit(10+i,'npc_dota_creep_badguys_melee',3,hero.pos.x+40*i,hero.pos.y),2,clock); c.attacking=true; s.creeps[#s.creeps+1]=c end; assert(B.threat.safety(s))")

    def test_no_laning_steal_even_defending_tower(self):
        self.check("core.pos=Vector(-6300,-6200,0); local c=unit(3,'npc_dota_creep_badguys_melee',3,-6300,-6200); c.hp=30; local t=unit(4,'npc_dota_goodguys_tower1_bot',2,-6500,-6200); world={hero,core,c,t}; local s=B.adapter.refresh(); for _,m in ipairs(B.modes.candidates(s)) do assert(not (m.intent and m.intent.kind=='attack' and m.target and m.target.index==3),m.name) end")

    def test_deny_allowed(self):
        self.check("local c=unit(3,'npc_dota_creep_goodguys_melee',2,-6300,-6200); c.hp=30; world[#world+1]=c; local s=B.adapter.refresh(); local found=false; for _,m in ipairs(B.modes.candidates(s)) do if m.name=='deny' then found=true end end; assert(found)")

    def test_abandoned_last_hit(self):
        self.check("core.alive=false; local c=unit(3,'npc_dota_creep_badguys_melee',3,-6300,-6200); c.hp=30; world[#world+1]=c; local s=B.adapter.refresh(); local found=false; for _,m in ipairs(B.modes.candidates(s)) do if m.name=='last_hit' then found=true end end; assert(found)")

    def test_charge_lock(self):
        self.check("hero.mods.modifier_spirit_breaker_charge_of_darkness=true; local s=B.adapter.refresh(); assert(not B.executor.execute(s,{kind='move',pos=core.pos})); assert(#orders==0)")

    def test_channel_lock(self):
        self.check("hero.channeling=true; local s=B.adapter.refresh(); assert(not B.executor.execute(s,{kind='hold'})); assert(#orders==0)")

    def test_cast_nil_return_is_accepted_and_confirmed(self):
        self.check("hero.abilities[0]=ability('spirit_breaker_bulldoze',4,0,0); local s=B.adapter.refresh(); local a=s.abilities.spirit_breaker_bulldoze; assert(B.executor.execute(s,{kind='cast',ability=a,castType='none'})); assert(B.executor.pending); hero.abilities[0].cooldown=10; clock=clock+.5; B.executor.poll(B.adapter.refresh()); assert(not B.executor.pending and B.executor.lastResult.ok)")

    def test_wrong_cast_type_rejected(self):
        self.check("hero.items[0]=ability('item_magic_wand',4,0,0); local s=B.adapter.refresh(); assert(not B.executor.execute(s,{kind='cast',ability=s.items.item_magic_wand,castType='target',target=s.hero})); assert(#orders==0)")

    def test_attack_windup_protected(self):
        self.check("local c=unit(3,'npc_dota_creep_badguys_melee',3,-6300,-6200); world[#world+1]=c; local s=B.adapter.refresh(); assert(B.executor.execute(s,{kind='attack',target=s.byIndex[3]})); s.now=s.now+.2; assert(not B.executor.execute(s,{kind='move',pos=core.pos}))")

    def test_unbounded_attack_chase_rejected(self):
        self.check("local s=B.adapter.refresh(); assert(not B.executor.execute(s,{kind='attack',target=s.core}))")

    def test_unreachable_path_not_issued(self):
        self.check("GridNav.BuildPath=function() return {} end; local s=B.adapter.refresh(); assert(not B.executor.execute(s,{kind='move',pos=core.pos})); assert(#orders==0)")

    def test_identical_orders_are_throttled(self):
        self.check("local s=B.adapter.refresh(); assert(B.executor.execute(s,{kind='move',pos=core.pos})); s.now=s.now+.2; assert(not B.executor.execute(s,{kind='move',pos=core.pos}))")

    def test_macro_disabled_then_enabled(self):
        self.check("assert(not DotaAI.Command('MOVE_TO',{position=core.pos})); DotaAI.SetExternalEnabled(true); local ok,seq=DotaAI.Command('MOVE_TO',{position=core.pos}); assert(ok and seq==1); DotaAI.Cancel(); assert(DotaAI.GetObservation().completedSequence==1)")

    def test_unknown_action_rejected(self):
        self.check("DotaAI.SetExternalEnabled(true); assert(not DotaAI.Command('SOMETHING'))")

    def test_observation_serializable_no_handles(self):
        self.check("B.state=B.adapter.refresh(); local o=DotaAI.GetObservation(); assert(o.botEnabled and o.role==5 and not o.recordingEnabled); assert(o.hero.handle==nil); assert(o.route and o.modeDesires)")

    def test_button_click_release_and_drag(self):
        self.check("mouseX=50; mouseY=155; mouseDown=true; B.ui.input(); assert(B.enabled); mouseDown=false; B.ui.input(); assert(not B.enabled); mouseDown=true; B.ui.input(); mouseX=150; B.ui.input(); mouseDown=false; B.ui.input(); assert(not B.enabled and B.ui.x==140)")

    def test_off_sends_stop_only_once(self):
        self.check("B.state=B.adapter.refresh(); B.setEnabled(false); local n=#orders; B.script.OnUpdate(); B.setEnabled(false); assert(#orders==n)")

    def test_dispenser_refused(self):
        self.check("hero.items[0]=ability('item_ward_dispenser',16,500,0); local s=B.adapter.refresh(); assert(not B.executor.execute(s,{kind='cast',ability=s.items.item_ward_dispenser,castType='position',pos=hero.pos}))")

    def test_quickbuy_retained_until_observed(self):
        self.check("clock=800; local s=B.adapter.refresh(); local i=B.items.purchase(s); assert(i.kind=='quickbuy'); assert(B.executor.execute(s,i)); assert(B.items.purchase(s)==nil); hero.items[0]=ability(i.itemName,4,0,0); clock=clock+1; local next=B.items.purchase(B.adapter.refresh()); assert(next and next.itemName~=i.itemName)")

    def test_requested_core_purchase_order(self):
        self.check("clock=800; local function next(name,slot) local i=B.items.purchase(B.adapter.refresh()); assert(i and i.itemName==name,name..' expected'); hero.items[slot]=ability(name,4,0,0); clock=clock+1 end; next('item_boots',0); next('item_phase_boots',1); next('item_invis_sword',2); next('item_yasha_and_kaya',3); next('item_silver_edge',4)")

    def test_eul_branch_when_dispersal_is_needed(self):
        self.check("clock=800; hero.items[0]=ability('item_phase_boots',4,0,0); hero.items[1]=ability('item_invis_sword',4,0,0); hero.silenced=true; local i=B.items.purchase(B.adapter.refresh()); assert(i and i.itemName=='item_cyclone')")

    def test_consumed_upgrades_are_not_bought_again(self):
        self.check("clock=2000; hero.items[0]=ability('item_phase_boots',4,0,0); hero.items[1]=ability('item_silver_edge',4,0,0); hero.items[2]=ability('item_yasha_and_kaya',4,0,0); hero.mods.modifier_item_aghanims_shard=true; hero.mods.modifier_item_ultimate_scepter_consumed=true; local i=B.items.purchase(B.adapter.refresh()); assert(i and i.itemName~='item_aghanims_shard' and i.itemName~='item_ultimate_scepter')")

    def test_tango_uses_observed_tree(self):
        self.check("hero.hp=600; local tree={index=50,pos=Vector(-6350,-6200,0)}; Entity.GetTreesInRadius=function() return {tree} end; hero.items[0]=ability('item_tango',8,165,0); local s=B.adapter.refresh(); local i=B.items.consider(s,{name='lane'}); assert(i and i.castType=='tree' and i.target.index==50); assert(B.executor.execute(s,i)); assert(orders[#orders].kind=='cast_target')")

    def test_group_avoids_pos1_between_ten_and_thirty(self):
        self.check("clock=800; core.pos=Vector(-6300,-6200,0); local support=unit(3,'npc_dota_hero_lion',2,-3500,-6200); support.roleFlags=8; local supportPlayer={hero=support}; world={hero,core,support}; Players.GetAll=function() return {player,corePlayer,supportPlayer} end; local s=B.adapter.refresh(); assert(B.modes.groupTarget(s).index==3); clock=2000; s=B.adapter.refresh(); assert(B.modes.groupTarget(s).index==2)")

    def test_recovery_hysteresis(self):
        self.check("local s=B.adapter.refresh(); s.hero.hpPct=.2; assert(B.arbiter.choose(s).name=='retreat'); s.now=s.now+2; s.hero.hpPct=.5; assert(B.arbiter.choose(s).name=='retreat'); s.hero.hpPct=.9; s.hero.manaPct=.9; s.now=s.now+2; assert(B.arbiter.choose(s).name~='retreat')")

    def test_visible_projectile_inference(self):
        self.check("local e=unit(3,'npc_dota_hero_lina',3,-6000,-6200); world[#world+1]=e; B.state=B.adapter.refresh(); B.script.OnProjectile({source=e,target=hero,isAttack=true,moveSpeed=1000,handle=90}); clock=clock+.1; local s=B.adapter.refresh(); assert(s.byIndex[3].attackTarget==1 and #s.projectiles==1)")

    def test_no_runtime_errors_long_simulated_clock(self):
        self.check("for i=1,1800 do clock=100+i; B.script.OnUpdate(); assert(not B.error,B.error) end; assert(not B.config.bridgeEnabled)")

    def test_bundle_loads_without_require(self):
        source = bundle()
        self.lua.execute('require=function() error("unexpected runtime dependency") end')
        callbacks = self.lua.execute(source.read_text(encoding='utf-8'))
        self.assertIsNotNone(callbacks.OnUpdate)
        callbacks.OnUpdate()

    def test_charge_interrupt_with_support(self):
        self.check("core.pos=Vector(-6500,-6200,0); local e=unit(3,'npc_dota_hero_lina',3,-5800,-6200); e.channeling=true; world[#world+1]=e; hero.abilities[0]=ability('spirit_breaker_charge_of_darkness',8,99999,2); local s=B.adapter.refresh(); local i=B.hero.consider(s,{name='fight'}); assert(i and i.ability.name=='spirit_breaker_charge_of_darkness')")

    def test_charge_refuses_enemy_tower(self):
        self.check("core.pos=Vector(-6500,-6200,0); local e=unit(3,'npc_dota_hero_lina',3,-5800,-6200); e.channeling=true; local t=unit(4,'npc_dota_badguys_tower1_mid',3,-5600,-6200); t.range=700; world={hero,core,e,t}; hero.abilities[0]=ability('spirit_breaker_charge_of_darkness',8,99999,2); local s=B.adapter.refresh(); assert(not B.hero.consider(s,{name='fight'}))")

    def test_charge_refuses_unsupported_global_initiation(self):
        self.check("local e=unit(3,'npc_dota_hero_lina',3,hero.pos.x+1200,hero.pos.y); world[#world+1]=e; hero.abilities[0]=ability('spirit_breaker_charge_of_darkness',8,99999,2); local s=B.adapter.refresh(); assert(not B.hero.consider(s,{name='fight'}))")

    def test_tower_push_requires_creep_tank(self):
        self.check("clock=800; core.pos=Vector(-6500,-6200,0); local t=unit(4,'npc_dota_badguys_tower1_mid',3,-6270,-6200); t.range=700; world={hero,core,t}; for i=1,3 do world[#world+1]=unit(10+i,'npc_dota_creep_goodguys_melee',2,-6200,-6200+i*10) end; t.target=world[4]; local s=B.adapter.refresh(); local found=false; for _,m in ipairs(B.modes.candidates(s)) do if m.name=='push' then found=true; assert(m.intent.allowTower) end end; assert(found); t.target=hero; s=B.adapter.refresh(); assert(B.arbiter.choose(s,B.threat.safety(s)).name=='SAFETY')")

    def test_observer_queue_not_overwritten(self):
        self.check("Item.GetStockCount=function() return 2 end; local s=B.adapter.refresh(); local i=B.items.purchase(s); assert(i.itemNames[1]=='item_wind_lace' and i.itemNames[#i.itemNames]=='item_faerie_fire'); B.executor.execute(s,i); clock=clock+1; assert(B.items.purchase(B.adapter.refresh())==nil)")

    def test_starting_queue_serialized_without_resets(self):
        self.check("local s=B.adapter.refresh(); local i=B.items.purchase(s); B.executor.execute(s,i); for n=1,7 do clock=clock+.3; s=B.adapter.refresh(); B.executor.poll(s) end; assert(#orders==5); assert(orders[1].args[1]=='wind_lace' and orders[1].args[2]==true); for n=2,5 do assert(orders[n].args[2]==false) end; assert(orders[2].args[1]=='branches' and orders[3].args[1]=='branches' and orders[4].args[1]=='tango' and orders[5].args[1]=='faerie_fire')")

    def test_optional_missing_ward_does_not_block_boots(self):
        self.check("Item.GetStockCount=function() return 2 end; local s=B.adapter.refresh(); local i=B.items.purchase(s); B.executor.execute(s,i); for n=1,7 do clock=clock+.3; B.executor.poll(B.adapter.refresh()) end; for n,name in ipairs({'item_wind_lace','item_branches','item_branches','item_tango','item_faerie_fire'}) do hero.items[n-1]=ability(name,4,0,0) end; local next=B.items.purchase(B.adapter.refresh()); assert(next and next.itemName=='item_boots')")

    def test_existing_quickbuy_is_not_erased_on_reload(self):
        self.check("local s=B.adapter.refresh(); s.quickbuy={m_quickBuyItems={34,39,16}}; assert(not B.items.purchase(s)); assert(#orders==0)")

    def test_old_ward_only_queue_does_not_block_starting_kit(self):
        self.check("local s=B.adapter.refresh(); s.quickbuy={m_quickBuyItems={42}}; local i=B.items.purchase(s); assert(i and i.itemNames[1]=='item_wind_lace' and i.reset)")

    def test_empty_starting_queue_is_repaired(self):
        self.check("local s=B.adapter.refresh(); local i=B.items.purchase(s); B.executor.execute(s,i); for n=1,7 do clock=clock+.3; B.executor.poll(B.adapter.refresh()) end; clock=clock+5; s=B.adapter.refresh(); s.quickbuy={m_quickBuyItems={}}; local retry=B.items.purchase(s); assert(retry and #retry.itemNames==5)")

    def test_front_tower_not_t3_selected_for_all_roles(self):
        self.check("for _,team in ipairs({2,3}) do for _,flags in ipairs({8,16}) do hero.team=team; hero.roleFlags=flags; core.alive=false; local lane=((team==2)==(flags==16)) and 'bot' or 'top'; local sign=team==2 and 1 or -1; local t3=unit(4,'npc_dota_goodguys_tower3_'..lane,team,-6000*sign,-5500*sign); local t1=unit(5,'npc_dota_goodguys_tower1_'..lane,team,2000*sign,-5500*sign); local t2=unit(6,'npc_dota_goodguys_tower2_'..lane,team,-1000*sign,-5500*sign); world={hero,t3,t1,t2}; local s=B.adapter.refresh(); assert(B.map.laneTower(s,lane).index==5); assert(B.dist(B.map.lanePoint(s,lane),t1.pos)<250) end end")

    def test_base_wave_does_not_pull_destination_back(self):
        self.check("core.alive=false; local t1=unit(4,'npc_dota_goodguys_tower1_bot',2,2000,-5500); local back=unit(5,'npc_dota_creep_goodguys_melee',2,-5000,-5500); local front=unit(6,'npc_dota_creep_goodguys_melee',2,2500,-5500); world={hero,t1,back,front}; local s=B.adapter.refresh(); assert(B.dist(B.map.lanePoint(s,'bot'),front.pos)<450)")

    def test_core_waiting_on_base_not_a_lane_anchor(self):
        self.check("core.pos=Vector(-6500,-6300,0); local t1=unit(4,'npc_dota_goodguys_tower1_bot',2,2000,-5500); world={hero,core,t1}; local s=B.adapter.refresh(); assert(not B.map.coreOnLane(s,s.core)); for _,m in ipairs(B.modes.candidates(s)) do if m.name=='lane' then assert(B.dist(m.pos,t1.pos)<250) end end")

    def test_force_staff_uses_observed_facing(self):
        self.check("hero.pos=Vector(1000,1000,0); hero.facing=Vector(-1,0,0); hero.hp=400; core.pos=Vector(950,1000,0); local e=unit(3,'npc_dota_hero_lina',3,1200,1000); world[#world+1]=e; hero.items[0]=ability('item_force_staff',8,550,3); hero.items[0].specials.push_length=600; local s=B.adapter.refresh(); s.hero.recentDamage=100; local i=B.items.consider(s,{name='retreat'}); assert(i and i.ability.name=='item_force_staff')")

    def test_spell_projectile_not_misread_as_autoattack(self):
        self.check("local e=unit(3,'npc_dota_hero_lina',3,-6000,-6200); world[#world+1]=e; B.state=B.adapter.refresh(); B.script.OnProjectile({source=e,target=hero,isAttack=false,moveSpeed=1000,handle=90}); clock=clock+.1; local s=B.adapter.refresh(); assert(s.byIndex[3].attackTarget==nil)")

    def test_json_unicode_roundtrip(self):
        self.check(r'''local data=B.json:decode([[{"reason":"\u0440\u0443\u043d\u0430"}]]); assert(data.reason=='руна'); assert(B.json:decode(B.json:encode(data)).reason=='руна')''')

    def test_external_macro_yields_to_safety(self):
        self.check("B.state=B.adapter.refresh(); DotaAI.SetExternalEnabled(true); DotaAI.Command('FOLLOW_CORE',{},15); local s=B.state; local m=B.arbiter.choose(s,{name='SAFETY',desire=1.5,reason='tower',pos=hero.pos}); assert(m.name=='SAFETY')")

    def test_level_read_from_documented_api(self):
        self.check("assert(NPC.GetLevel==nil); hero.level=2; local s=B.adapter.refresh(); assert(s.hero.level==2)")

    def test_human_build_bash_then_charge(self):
        self.check("hero.points=1; local q=ability('spirit_breaker_charge_of_darkness',8,0,2); q.level=0; q.upgradable=true; local e=ability('spirit_breaker_greater_bash',2,0,0); e.level=0; e.upgradable=true; hero.abilities[0]=q; hero.abilities[2]=e; local s=B.adapter.refresh(); assert(B.hero.level(s).ability.name=='spirit_breaker_greater_bash'); e.level=1; s=B.adapter.refresh(); assert(B.hero.level(s).ability.name=='spirit_breaker_charge_of_darkness')")

    def test_bulldoze_allowed_near_charge_impact(self):
        self.check("local q=ability('spirit_breaker_charge_of_darkness',8,0,2); local w=ability('spirit_breaker_bulldoze',4,0,0); hero.abilities[0]=q; hero.abilities[1]=w; local e=unit(3,'npc_dota_hero_lina',3,-5000,-6200); world={hero,core,e}; hero.mods.modifier_spirit_breaker_charge_of_darkness=true; B.chargeTarget={index=3,issuedAt=clock-3}; local s=B.adapter.refresh(); local i=B.hero.consider(s,{name='gank'}); assert(i and i.ability.name=='spirit_breaker_bulldoze'); assert(B.executor.execute(s,i)); assert(orders[#orders].kind=='cast_none')")

    def test_global_low_hp_charge(self):
        self.check("local e=unit(3,'npc_dota_hero_lina',3,4500,4500); e.hp=240; world={hero,core,e}; hero.abilities[0]=ability('spirit_breaker_charge_of_darkness',8,0,2); local s=B.adapter.refresh(); local i=B.hero.consider(s,{name='patrol'}); assert(i and i.lowHpFinisher and i.target.index==3); assert(B.executor.execute(s,i)); assert(orders[#orders].kind=='cast_target')")

    def test_low_hp_charge_requires_mana_and_cooldown(self):
        self.check("local e=unit(3,'npc_dota_hero_lina',3,4500,4500); e.hp=200; world={hero,core,e}; local q=ability('spirit_breaker_charge_of_darkness',8,0,2); hero.abilities[0]=q; hero.mana=20; local s=B.adapter.refresh(); assert(not B.hero.consider(s,{name='patrol'})); hero.mana=500; q.cooldown=10; s=B.adapter.refresh(); assert(not B.hero.consider(s,{name='patrol'}))")

    def test_low_hp_charge_ignores_fog_and_retreat(self):
        self.check("local e=unit(3,'npc_dota_hero_lina',3,4500,4500); e.hp=100; e.visible=false; world={hero,core,e}; hero.abilities[0]=ability('spirit_breaker_charge_of_darkness',8,0,2); local s=B.adapter.refresh(); assert(not B.hero.consider(s,{name='patrol'})); e.visible=true; s=B.adapter.refresh(); assert(not B.hero.consider(s,{name='SAFETY'}))")

    def test_base_charge_uses_safe_creep_when_tp_on_cooldown(self):
        self.check("hero.pos=Vector(-7050,-6550,0); local q=ability('spirit_breaker_charge_of_darkness',8,0,2); local tp=ability('item_tpscroll',16,99999,0); tp.cooldown=20; hero.abilities[0]=q; hero.items[15]=tp; core.pos=Vector(1000,-5000,0); local c=unit(3,'npc_dota_creep_badguys_melee',3,1200,-5000); local cover1=unit(4,'npc_dota_creep_goodguys_melee',2,1000,-5000); local cover2=unit(5,'npc_dota_creep_goodguys_melee',2,1050,-5000); world={hero,core,c,cover1,cover2}; local s=B.adapter.refresh(); local i=B.hero.consider(s,{name='lane'}); assert(i and i.baseExitCharge and i.target.index==3); assert(B.executor.execute(s,i))")

    def test_base_charge_waits_when_tp_ready(self):
        self.check("hero.pos=Vector(-7050,-6550,0); local q=ability('spirit_breaker_charge_of_darkness',8,0,2); local tp=ability('item_tpscroll',16,99999,0); tp.cooldown=0; hero.abilities[0]=q; hero.items[15]=tp; core.pos=Vector(1000,-5000,0); local c=unit(3,'npc_dota_creep_badguys_melee',3,1200,-5000); local cover1=unit(4,'npc_dota_creep_goodguys_melee',2,1000,-5000); local cover2=unit(5,'npc_dota_creep_goodguys_melee',2,1050,-5000); world={hero,core,c,cover1,cover2}; local s=B.adapter.refresh(); local i=B.hero.consider(s,{name='lane'}); assert(not i or not i.baseExitCharge)")

    def test_base_charge_when_tp_missing(self):
        self.check("hero.pos=Vector(-7050,-6550,0); hero.abilities[0]=ability('spirit_breaker_charge_of_darkness',8,0,2); local c=unit(3,'npc_dota_creep_badguys_melee',3,1200,-5000); world={hero,core,c}; local s=B.adapter.refresh(); local i=B.hero.consider(s,{name='lane'}); assert(i and i.baseExitCharge and i.target.index==3)")

    def test_free_farm_charge_can_target_creep_after_laning(self):
        self.check("clock=800; hero.pos=Vector(0,0,0); core.pos=Vector(-5000,-5000,0); local q=ability('spirit_breaker_charge_of_darkness',8,0,2); hero.abilities[0]=q; local c=unit(3,'npc_dota_creep_badguys_melee',3,1800,0); world={hero,core,c}; local s=B.adapter.refresh(); local i=B.hero.consider(s,{name='lane'}); assert(i and i.farmCharge and i.target.index==3); assert(B.executor.execute(s,i))")

    def test_quiet_group_mode_yields_to_farm_charge(self):
        self.check("clock=800; hero.pos=Vector(100,0,0); core.pos=Vector(-5000,-5000,0); hero.abilities[0]=ability('spirit_breaker_charge_of_darkness',8,0,2); local c=unit(3,'npc_dota_creep_badguys_melee',3,1900,0); world={hero,core,c}; local s=B.adapter.refresh(); local i=B.hero.consider(s,{name='group'}); assert(i and i.farmCharge and i.target.index==3); local m=B.arbiter.choose(s); assert(m.name=='farm',m.name)")

    def test_free_farm_charge_yields_to_map_fight(self):
        self.check("clock=800; hero.pos=Vector(0,0,0); core.pos=Vector(-5000,-5000,0); local q=ability('spirit_breaker_charge_of_darkness',8,0,2); hero.abilities[0]=q; local c=unit(3,'npc_dota_creep_badguys_melee',3,1800,0); local ally=unit(4,'npc_dota_hero_axe',2,5000,5000); local foe=unit(5,'npc_dota_hero_lina',3,5100,5000); world={hero,core,c,ally,foe}; local s=B.adapter.refresh(); s.byIndex[4].recentDamage=20; local i=B.hero.consider(s,{name='lane'}); assert(not i or not i.farmCharge)")

    def test_lane_setup_avoids_four_creep_aggro(self):
        self.check("hero.pos=Vector(4000,-5500,0); hero.hp=900; core.pos=Vector(3900,-5700,0); core.hp=900; local e=unit(3,'npc_dota_hero_lina',3,4300,-5500); world={hero,core,e}; for n=1,4 do local c=unit(3+n,'npc_dota_creep_badguys_melee',3,4250+n*10,-5500); c.range=150; world[#world+1]=c end; local s=B.adapter.refresh(); for _,m in ipairs(B.support.candidates(s)) do assert(m.name~='harass') end")

    def test_level_one_charge_in_local_fight_despite_patrol_mode(self):
        self.check("hero.level=1; hero.pos=Vector(4000,-5500,0); core.pos=Vector(4700,-5400,0); local e=unit(3,'npc_dota_hero_lina',3,4900,-5400); e.level=1; world={hero,core,e}; hero.abilities[0]=ability('spirit_breaker_charge_of_darkness',8,0,2); local s=B.adapter.refresh(); s.core.recentDamage=40; local i=B.hero.consider(s,{name='patrol'}); assert(i and i.ability.name=='spirit_breaker_charge_of_darkness'); assert(B.executor.execute(s,i))")

    def test_zero_range_other_spell_not_treated_as_global(self):
        self.check("local a={name='spirit_breaker_nether_strike',range=0}; assert(not B.inCastRange(a,900)); assert(B.inCastRange({name='spirit_breaker_charge_of_darkness',range=0},900))")

    def test_creep_farming_ally_does_not_trigger_local_charge(self):
        self.check("hero.pos=Vector(4000,-5500,0); core.pos=Vector(4500,-5400,0); core.attacking=true; local e=unit(3,'npc_dota_hero_lina',3,4800,-5400); world={hero,core,e}; hero.abilities[0]=ability('spirit_breaker_charge_of_darkness',8,0,2); local s=B.adapter.refresh(); assert(not B.support.localFight(s,s.byIndex[3])); assert(not B.hero.consider(s,{name='patrol'}))")

    def test_teamfight_does_not_disengage_after_each_hit(self):
        self.check("hero.pos=Vector(4000,-5500,0); core.pos=Vector(4050,-5400,0); local e=unit(3,'npc_dota_hero_lina',3,4120,-5500); world={hero,core,e}; local s=B.adapter.refresh(); s.core.recentDamage=30; local hit; for _,m in ipairs(B.support.candidates(s)) do if m.target and m.target.index==3 and m.intent.kind=='attack' then hit=m.intent end end; assert(hit and not hit.trade); B.executor.execute(s,hit); s.now=s.now+.1; for _,m in ipairs(B.support.candidates(s)) do assert(m.name~='trade_reset') end")

    def test_lane_patrol_moves_in_equal_two_vs_two(self):
        self.check("hero.pos=Vector(4000,-5500,0); core.pos=Vector(4000,-5700,0); local e=unit(3,'npc_dota_hero_lina',3,4400,-5400); local e2=unit(4,'npc_dota_hero_undying',3,4650,-5400); world={hero,core,e,e2}; local s=B.adapter.refresh(); local m=B.arbiter.choose(s); local i=B.arbiter.intent(s,m); assert(m.name~='idle'); assert(i and i.kind~='hold')")

    def test_patrol_target_stable_until_arrival(self):
        self.check("hero.pos=Vector(4000,-5500,0); core.pos=Vector(4000,-5700,0); local s=B.adapter.refresh(); local p; for _,m in ipairs(B.support.candidates(s)) do if m.name=='patrol' then p=m.pos end end; assert(p); s.now=s.now+.12; local q; for _,m in ipairs(B.support.candidates(s)) do if m.name=='patrol' then q=m.pos end end; assert(B.dist(p,q)<1); s.hero.pos=p; s.now=s.now+.12; for _,m in ipairs(B.support.candidates(s)) do if m.name=='patrol' then assert(B.dist(m.pos,p)>100) end end")

    def test_peel_for_injured_core_under_own_tower(self):
        self.check("hero.pos=Vector(4000,-5500,0); core.pos=Vector(3750,-5400,0); core.hp=450; local e=unit(3,'npc_dota_hero_lina',3,4200,-5400); local e2=unit(4,'npc_dota_hero_undying',3,4350,-5200); local t=unit(5,'npc_dota_goodguys_tower1_bot',2,3800,-5550); t.range=700; world={hero,core,e,e2,t}; local s=B.adapter.refresh(); local found=false; for _,m in ipairs(B.support.candidates(s)) do if m.name=='protect_core' then found=true; assert(m.intent.kind=='move' or m.intent.kind=='attack') end end; assert(found)")

    def test_short_trade_persists_for_multiple_hits(self):
        self.check("hero.pos=Vector(4000,-5500,0); core.pos=Vector(3700,-5500,0); local e=unit(3,'npc_dota_hero_lina',3,4120,-5500); world={hero,core,e}; local s=B.adapter.refresh(); local hit; for _,m in ipairs(B.support.candidates(s)) do if m.name=='harass' then hit=m.intent end end; assert(hit and hit.kind=='attack'); assert(B.executor.execute(s,hit)); s.now=s.now+.6; local follow; for _,m in ipairs(B.support.candidates(s)) do if m.name=='harass' then follow=m.intent end assert(m.name~='trade_reset') end; assert(follow and follow.kind=='attack' and follow.tradeContinue)")

    def gank_setup(self):
        self.check("hero.pos=Vector(4000,-5500,0); hero.level=2; core.pos=Vector(3800,-5700,0); remote=unit(3,'npc_dota_hero_axe',2,1100,1100); remote.attacking=true; foe=unit(4,'npc_dota_hero_lina',3,1000,1200); foe.hp=600; world={hero,core,remote,foe}; hero.abilities[0]=ability('spirit_breaker_charge_of_darkness',8,99999,2)")

    def test_level_two_gank_on_other_lane(self):
        self.gank_setup()
        self.check("local s=B.adapter.refresh(); assert(B.support.canGank(s,s.byIndex[4])); local m=B.arbiter.choose(s); assert(m.name=='gank',m.name); local i=B.hero.consider(s,m); assert(i and i.gank and i.target.index==4); assert(B.executor.execute(s,i)); assert(not B.support.canGank(s,s.byIndex[4]))")

    def test_level_one_cannot_gank(self):
        self.gank_setup()
        self.check("hero.level=1; local s=B.adapter.refresh(); assert(not B.support.canGank(s,s.byIndex[4]))")

    def test_gank_does_not_abandon_threatened_core(self):
        self.gank_setup()
        self.check("core.hp=400; local localFoe=unit(5,'npc_dota_hero_undying',3,3900,-5700); world[#world+1]=localFoe; local s=B.adapter.refresh(); assert(B.support.coreDanger(s)); assert(not B.support.canGank(s,s.byIndex[4]))")

    def test_gank_path_avoids_known_tower(self):
        self.gank_setup()
        self.check("local t=unit(5,'npc_dota_badguys_tower1_mid',3,2500,-2150); t.range=700; world[#world+1]=t; local s=B.adapter.refresh(); assert(not B.support.canGank(s,s.byIndex[4]))")

    def test_gank_does_not_target_fog(self):
        self.gank_setup()
        self.check("foe.visible=false; local s=B.adapter.refresh(); assert(not B.support.canGank(s,s.byIndex[4]))")

    def test_lane_ward_can_be_cast_without_totally_empty_lane(self):
        self.check("hero.pos=Vector(5450,-4850,0); core.pos=Vector(5550,-4700,0); hero.items[0]=ability('item_ward_observer',16,500,0); local e=unit(3,'npc_dota_hero_lina',3,6200,-4400); world={hero,core,e}; local s=B.adapter.refresh(); local ward; for _,m in ipairs(B.support.candidates(s)) do if m.name=='ward' and m.intent.kind=='cast' then ward=m.intent end end; assert(ward and ward.wardSpot); assert(B.executor.execute(s,ward))")

    def test_faerie_fire_is_used_under_lethal_pressure(self):
        self.check("hero.hp=250; hero.items[0]=ability('item_faerie_fire',4,0,0); local e=unit(3,'npc_dota_hero_lina',3,-6300,-6200); world={hero,core,e}; local s=B.adapter.refresh(); s.hero.recentDamage=100; local i=B.items.consider(s,{name='fight'}); assert(i and i.ability.name=='item_faerie_fire' and i.priority==97)")

    def test_obsolete_branch_is_sold_only_from_full_inventory_at_fountain(self):
        self.check("clock=1100; hero.pos=Vector(-7050,-6550,0); for slot,name in ipairs({'item_phase_boots','item_branches','item_faerie_fire','item_tango','item_invis_sword','item_yasha_and_kaya'}) do hero.items[slot-1]=ability(name,4,0,0) end; local s=B.adapter.refresh(); local i=B.items.cleanup(s); assert(i and i.kind=='sell' and i.item.name=='item_branches'); assert(B.executor.execute(s,i)); assert(orders[#orders].kind=='order' and orders[#orders].args[2]==17)")

    def test_game_start_greeting_is_sent_once_to_all_chat(self):
        self.check("B.script.OnGameStart(); B.script.OnUpdate(); clock=clock+.2; B.script.OnUpdate(); assert(#chats==1 and chats[1].channel=='All' and chats[1].message=='Удачи и веселой игры')")

    def test_game_start_greeting_retries_until_channels_exist(self):
        self.check("local calls=0; Chat.GetChannels=function() calls=calls+1; if calls<2 then return {} end return {'All','Team'} end; B.script.OnGameStart(); B.script.OnUpdate(); assert(#chats==0); clock=clock+2.1; B.script.OnUpdate(); assert(#chats==1 and calls==2)")

    def test_special_values_only_queried_on_relevant_items(self):
        self.check("Ability.GetLevelSpecialValueFor=function() error('unrelated special query') end; hero.abilities[0]=ability('spirit_breaker_charge_of_darkness',8,99999,2); local s=B.adapter.refresh(); assert(B.capabilities['Ability.GetLevelSpecialValueFor']==nil)")

if __name__ == '__main__':
    unittest.main()
