-- Contract mocks, not the real game. Failures here never substitute for lobby QA.
clock=100
orders={}
chats={}
Vector=function(x,y,z) return {x=x,y=y,z=z or 0} end
Vec2=function(x,y) return {x=x,y=y} end
Color=function(...) return {...} end
Enum={ModifierState={},ButtonCode={KEY_MOUSE1=1},UnitOrder={
    DOTA_UNIT_ORDER_MOVE_TO_POSITION=1,DOTA_UNIT_ORDER_TRAIN_ABILITY=11,
    DOTA_UNIT_ORDER_DROP_ITEM=12,DOTA_UNIT_ORDER_PICKUP_RUNE=15,
    DOTA_UNIT_ORDER_SELL_ITEM=17,DOTA_UNIT_ORDER_MOVE_ITEM=19},
    PlayerOrderIssuer={DOTA_ORDER_ISSUER_PASSED_UNIT_ONLY=0}}
function unit(index,name,team,x,y)
    return {index=index,name=name,team=team,pos=Vector(x,y,0),hp=1000,maxHp=1000,mana=500,maxMana=500,
        range=150,level=3,damage=65,alive=true,visible=true,abilities={},items={},mods={},facing=Vector(1,0,0)}
end
hero=unit(1,'npc_dota_hero_spirit_breaker',2,-6400,-6200)
core=unit(2,'npc_dota_hero_juggernaut',2,1000,-5000)
core.roleFlags=1
hero.roleFlags=16
world={hero,core}
player={hero=hero}
corePlayer={hero=core}
local function record(kind,...) orders[#orders+1]={kind=kind,args={...}} end
Engine={SetQuickBuy=function(name,reset) record('quickbuy',name,reset) end}
GameRules={GetGameTime=function() return clock end,GetDOTATime=function() return clock-90 end}
Heroes={GetLocal=function() return hero end}
Players={GetLocal=function() return player end,GetAll=function() return {player,corePlayer} end}
Player={GetTeamData=function(p) return {lane_selection_flags=p.hero.roleFlags} end,
    GetAssignedHero=function(p) return p.hero end,
    PrepareUnitOrders=function(...) record('order',...) end,
    AttackTarget=function(...) record('attack',...) end,
    HoldPosition=function(...) record('hold',...) end}
Entity={GetTeamNum=function(u) return u.team end,IsDormant=function(u) return u.visible==false end,
    GetAbsOrigin=function(u) assert(u.team==hero.team or u.visible~=false,'FOG POSITION READ') return u.pos end,
    GetIndex=function(u) return u.index end,GetHealth=function(u) return u.hp end,
    GetMaxHealth=function(u) return u.maxHp end,IsAlive=function(u) return u.alive end,
    IsHero=function(u) return u.name:find('npc_dota_hero_')==1 end,
    IsEntity=function(u) return u~=nil and not u.removed end,
    GetForwardPosition=function(u,d) return Vector(u.pos.x+u.facing.x*d,u.pos.y+u.facing.y*d,u.pos.z) end,
    GetTreesInRadius=function() return {} end}
NPCs={GetAll=function() return world end}
NPC={GetUnitName=function(u) return u.name end,IsVisible=function(u) return u.visible end,
    GetMana=function(u) return u.mana end,GetMaxMana=function(u) return u.maxMana end,
    IsIllusion=function(u) return u.illusion or false end,GetAttackRange=function(u) return u.range end,
    GetAttackRangeBonus=function() return 0 end,GetTrueDamage=function(u) return u.damage end,
    GetArmorDamageMultiplier=function() return 1 end,GetMoveSpeed=function() return 300 end,
    GetAttackAnimPoint=function() return .3 end,GetSecondsPerAttack=function(u,flag) assert(flag~=nil) return 1.5 end,
    GetAttackProjectileSpeed=function(u) return u.range>250 and 900 or 0 end,
    IsAttacking=function(u) return u.attacking or false end,IsChannellingAbility=function(u) return u.channeling or false end,
    GetCurrentLevel=function(u) return u.level end,IsStunned=function(u) return u.stunned or false end,
    IsSilenced=function(u) return u.silenced or false end,HasState=function() return false end,
    GetModifiers=function(u) local out={} for name,_ in pairs(u.mods) do out[#out+1]={name=name} end return out end,
    IsTower=function(u) return u.name:find('tower')~=nil end,IsLaneCreep=function(u) return u.name:find('creep')~=nil end,
    IsNeutral=function(u) return u.team==4 end,IsStructure=function(u) return u.name:find('fountain')~=nil end,
    GetAbilityByIndex=function(u,slot) return u.abilities[slot] end,GetItemByIndex=function(u,slot) return u.items[slot] end}
Modifier={GetName=function(m) return m.name end}
Hero={GetAbilityPoints=function(u) return u.points or 0 end}
function ability(name,behavior,range,team)
    return {name=name,index=100,behavior=behavior,range=range,targetTeam=team,level=1,cooldown=0,charges=1,specials={},ready=true}
end
Ability={GetName=function(a) return a.name end,GetLevel=function(a) return a.level end,
    GetMaxLevel=function() return 4 end,IsCastable=function(a,mana) assert(mana~=nil) return a.ready and a.cooldown==0 end,
    GetCastRange=function(a) return a.range end,GetCastPoint=function() return 0.3 end,
    GetCooldown=function(a) return a.cooldown end,GetManaCost=function() return 50 end,
    GetBehavior=function(a) return a.behavior end,GetTargetTeam=function(a) return a.targetTeam end,
    IsHidden=function() return false end,IsPassive=function(a) return a.behavior==2 end,
    IsInAbilityPhase=function(a) return a.inPhase or false end,GetDamage=function() return 100 end,
    GetLevelSpecialValueFor=function(a,n) return a.specials[n] or 0 end,
    CanBeUpgraded=function(a) return a.upgradable or false end,
    CastTarget=function(...) record('cast_target',...) end,CastPosition=function(...) record('cast_position',...) end,
    CastNoTarget=function(...) record('cast_none',...) end}
Item={GetCurrentCharges=function(a) return a.charges end,GetSecondaryCharges=function() return 0 end,
    IsSellable=function(a) return a.sellable~=false end,IsDroppable=function(a) return a.droppable~=false end,
    GetCost=function(a) return a.cost or 50 end}
Chat={GetChannels=function() return {'All','Team','ConsoleChat'} end,
    Say=function(channel,message) chats[#chats+1]={channel=channel,message=message} end}
Tower={GetAttackTarget=function(t) return t.target end}
Couriers={GetLocal=function() return nil end}
Camps={GetAll=function() return {} end}
Runes={GetAll=function() return {} end}
Rune={GetRuneType=function() return 0 end}
LinearProjectiles={GetAll=function() return {} end}
GridNav={IsTraversable=function() return true end,BuildPath=function(a,b) return {a,b} end}
Input={GetCursorPos=function() return mouseX or 0,mouseY or 0 end,IsKeyDown=function() return mouseDown or false end}
Render={LoadFont=function() return 1 end,FilledRect=function() end,Rect=function() end,
    TextSize=function() return Vec2(70,18) end,Text=function() end}
Log={Write=function(line) end}
HTTP={Request=function() error('HTTP must not run by default') end}
