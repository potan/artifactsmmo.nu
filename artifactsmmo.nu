
use std/log

$env.API = "https://api.artifactsmmo.com/"
$env.API_TIMEOUT = 90sec
$env.PAGESIZE = 10

def title [txt: string = ""] {
  let txt = if $txt == "" {
    try { $env.CURCHR } catch { "MMO" }
  } else { $txt }
  print -n $"(ansi title)($txt)(ansi st)"
}

$env.config.hooks.pre_prompt = [{||
  title # (if "LAST_CMD" in $env { $env.LAST_CMD } else { "" })
}]

def "mmo get" [query] {
  let api = $env.API
  let timeout = $env.API_TIMEOUT
  try {
    http get --max-time $timeout $"($api)($query)"
  } catch { |err|
    print $query
    print $err
    log error $err.msg
    log debug $err.debug
    sleep 20sec
    mmo get $query
  }
}

def "mmo load" [query] {
  let r = mmo get $query
  let sep = if $query =~ \? { "&" } else { "?" }
  mut data = $r.data
  let pages = try { $r.pages } catch { 0 }
  if $pages > 1 {
    for page in 2..$pages {
     let r = mmo get $"($query)($sep)page=($page)"
     $data = $data | append $r.data
    }
  }
  $data
}

def --env "mmo load_monsters" [] {
  $env.MONSTERS = mmo load $"monsters?size=($env.PAGESIZE)"
}
mmo load_monsters

def --env "mmo load_map" [] {
  $env.MAP = mmo load $"maps?size=($env.PAGESIZE)"
}
mmo load_map

def monsters [] { $env.MONSTERS | get code }

def "mmo monster" [m: string@monsters] {
  let d = $env.MONSTERS | where code == $m | get 0
  let w = $env.MAP | where interactions.content != null and interactions.content.type == monster and interactions.content.code == $m | select x y layer
  $d | insert location $w
}

def --env "mmo load_items" [] {
  $env.ITEMS = mmo load $"items?size=($env.PAGESIZE)"
  $env.NPCS_ITEMS = mmo load $"npcs/items?size=($env.PAGESIZE)"
}
mmo load_items

def mitems [] { $env.ITEMS | get code }

def "mmo item" [m: string@mitems] { $env.ITEMS | where code == $m | get 0 }

def "mmo current" [] {
  mmo load events/active
# update $env.MAP
}

def "mmo find" [what: string] {
  mmo load $"maps?size=($env.PAGESIZE)&content_code=($what)"
}

let token = open artifactsmmo.token | lines | get 0

def "my get" [query] {
  let api = $env.API
  let timeout = $env.API_TIMEOUT
  try {
    http get --max-time $timeout --headers { Authorization: $"Bearer ($token)" } $"($api)my/($query)"
  } catch { |err|
    print $query
    print $err
    log error $err.msg
    log debug $err.debug
    sleep 20sec
    my get $query
  }
}

def "my load" [query] {
  let r = my get $query
  mut data = $r.data
  let pages = try { $r.pages } catch { 0 }
  if $pages > 1 {
    let sep = if $query =~ \? { "&" } else { "?" }
    for page in 2..$pages {
     let r = my get $"($query)($sep)page=($page)"
     $data = $data | append $r.data
    }
  }
  $data
}


def "my logs" [] {
  my load logs
}

def "my characters" [] {
  let cooldowns = try {
    $env.CHARACTERS | each  { |$c|  {0:$c.name, 1:$c.cooldown_until} } | transpose -r | get 0
  } catch { {} }
  let d = date now
  my load characters | insert when $d | insert cooldown_until { |c| try { $cooldowns | get ($c.name) } catch { $d } }
}

def --env "mmo load_characters" [] {
  $env.CHARACTERS = my characters
}
mmo load_characters

def characters [] { $env.CHARACTERS | get name }

def "my log" [name: string@characters] {
  my load $"logs/($name)"
}

def actions [] {
  [move, fight, rest, transition, equip, unequip, use, gathering, crafting, bank/deposit/gold, bank/deposit/item,
  bank/withdraw/item, bank/withdraw/gold, bank/buy_expansion, npc/buy, npc/sell, recycling, grandexchange/buy,
  grandexchange/sell, grandexchange/cancel, task/complete, task/exchange, task/new, task/trade, task/cancel,
  give/gold, give/item, delete]
}

def "mmo post" [--retry = true, action: string, data: any] {
  let api = $env.API
  let timeout = $env.API_TIMEOUT
  try {
    http post --max-time $timeout --allow-errors --headers { Authorization: $"Bearer ($token)", Content-Type: application/json } --content-type application/json $"($api)($action)" $data
  } catch { |err|
    print $action
    print $err
    log error $err.msg
    log debug $err.debug
    if $retry {
      mmo post $action $data
    }
  }
}

def --env "mmo create character" [name: string, skin: string = "women2"] {
  let resp = mmo post "characters/create" {name:$name, skin:$skin}
  match $resp {
    {data: $ch} => {
      $env.CHARACTERS = $env.CHARACTERS | append ($ch | insert when (date now) | insert cooldown_until (date now))
      $ch
    }
    {error: $error} => {
      print $error.message
      $error
    }
  }
}

def --env act [--retry = true, name: string@characters, action: string@actions, data: any = {}] {
  let wait_until = try {
    $env.CHARACTERS | where name == $name | get 0 | get cooldown_until
  } catch { date now }
  if $wait_until > (date now) {
    sleep ($wait_until - (date now))
  }
  let resp = mmo post --retry $retry $"my/($name)/action/($action)" $data
  match $resp {
    {data: $data} => {
      let cooldown = try { $data.cooldown.expiration | into datetime } catch { date now }
      let old = $env.CHARACTERS
      try {
        let new = $data.character
        $env.CHARACTERS = $old | where name != $name | append ($new | insert when (date now) | insert cooldown_until $cooldown)
      } catch { |err|
        let new = $data.characters
        let participants = $new | select name
        $env.CHARACTERS = $old | where { |row|
          ($participants | where name == $row.name) == []
        } | append ($new | insert when (date now) | insert cooldown_until $cooldown)
      }
      $data
    }
    {error: $error} => {
      match ($error.code) {
        490 => {
          {result: "DoNothing", character: ($env.CHARACTERS | where name == $name | get 0)}
        }
        499 => {
          sleep ($error.message | parse --regex '(?P<cooldown>\d+(?:\.\d*)?)' | get 0 | get cooldown | into duration --unit sec)
          act --retry $retry $name $action $data
        }
        _ => {
          print $error
          log error $error.message
          $error
        }
      }
    }
  }
}

def crafts [] {
  $env.ITEMS | where craft != null | get code
}

def need [item: string@crafts, quantity: int  = 1] {
   $env.ITEMS | where { |r| $r.code == $item } | get 0 | get craft.items | update quantity { |q| $q.quantity * $quantity}
}

def xy [x:int, y:int] {
  {x:$x, y:$y}
}

def item [code: string@mitems, num: int] {
  {code: $code, quantity: $num}
}

def "bank items" [] {
  my load bank/items | join $env.ITEMS code code | select code quantity level type subtype
}

def bag_items [context: string] {
  print $context
  let w = $context | split words
  let name = $w | get 1
  $env.CHARACTERS | where name == $name | get inventory | get 0 | where code != "" | get code
}

def has [name: string@characters, item: string@bag_items] {
  $env.CHARACTERS | where name == $name | get inventory | get 0 | where code == $item | get quantity | append [0] | get 0
}

def --env please [name: string@characters, block] {
  let save = try { $env.CURCHR } catch {|e| $name }
  $env.CURCHR = $name
#export-env $block
  do $block
  $env.CURCHR = $save
}

def --env work [action: string@actions, data: any = {}] {
  let chr = $env.CURCHR
  act $chr $action $data
}

def --env deposit [mitems: list, name: string@characters = ""] {
  let chr = if $name == "" { $env.CURCHR } else { $name }
  let set = $env.CHARACTERS | where name == $name | get inventory | get 0 | where code in $mitems | select code quantity
#  let set = $mitems | each {|i| {code: $i, quantity:(has $chr $i)} } | where quantity != 0
  if $set != [] {
    act $chr bank/deposit/item $set
  }
}

def max [a, b] {
  if $a < $b { $b } else { $a }
}

def min [a, b] {
  if $a > $b { $b } else { $a }
}

# Fill utility slot.
def --env efill [uslot, potion, name: string@characters = ""] {
  let chr = if $name == "" { $env.CURCHR } else { $name }
  let c = $env.CHARACTERS | where name == $chr | get 0
  let n = 100 - ($c | get $"utility($uslot)_slot_quantity")
  let m = min $n (has $chr $potion)
  if $m > 0 {
    act $chr equip [{code:$potion, slot:$"utility($uslot)", quantity:$m}]
  }
}

def inventory [w: string@mitems = ""] {
  let i = $env.CHARACTERS | each { |c| $c.inventory | where code != "" | insert name $c.name | select name code quantity } | flatten | join $env.ITEMS code code | select  name code quantity level type subtype # | append $bank
  if w == "" {
    $i
  } else {
    $i | where code =~ $w
  }
}

def errcode [r] {
  try {
    $r.code
  } catch { |e|
    200
  }
}

def --env cha [--load = true, name: string@characters = ""] {
  let chr = if $name == "" { $env.CURCHR } else { $name }
  if $load {
    mmo load_characters
  }
  $env.CHARACTERS | where name == $chr | get 0
}

def get_event [l, d] {
 mmo load events/active | join $l code code | insert place { |r| {x: $r.map.x, y: $r.map.y, layer: $r.map.layer } } | append [$d] | get 0
}

def slots [] {
  [weapon rune shield helmet body_armor leg_armor boots ring1 ring2 amulet artifact1 artifact2 artifact3 utility1 utility2 bag]
}

def slot [--load = false, slot: string@slots, name: string@characters = ""] {
  (cha --load $load $name) | get $"($slot)_slot"
}

def --env equip [e, name: string@characters = ""] {
  if (slot $e.slot $name) != $e.code {
    act $name equip [$e]
  }
}
