
$env.API = "https://api.artifactsmmo.com/"
def "mmo get" [query] {
  let api = $env.API
  http get $"($api)($query)"
}

def "mmo load" [query] {
  let r = mmo get $query
  mut data = $r.data
  let pages = $r.pages
  if $pages > 1 {
    for page in 2..$pages {
     let r = mmo get $"($query)?page=($page)"
     $data = $data | append $r.data
    }
  }
  $data
}

def --env "mmo load_monsters" [] {
  $env.MONSTERS = mmo load monsters
}
mmo load_monsters

def --env "mmo load_map" [] {
  $env.MAP = mmo load maps
}
mmo load_map

def monsters [] { $env.MONSTERS | get code }

def "mmo monster" [m: string@monsters] { $env.MONSTERS | where code == $m | get 0 }

def --env "mmo load_items" [] {
  $env.ITEMS = mmo load items
}
mmo load_items

def items [] { $env.ITEMS | get code }

def "mmo item" [m: string@items] { $env.ITEMS | where code == $m | get 0 }

let token = open artifactsmmo.token | lines | get 0

def "my characters" [] {
  let api = $env.API
  (http get --headers { Authorization: $"Bearer ($token)" } $"($api)my/characters").data | insert when (date now)
}

def --env "mmo load_characters" [] {
  $env.CHARACTERS = my characters
}
mmo load_characters

def characters [] { $env.CHARACTERS | get name }

def actions [] {
  [move, fight, rest]
}

def --env act [name: string@characters, action: string@actions, data] {
  let api = $env.API
  let resp = http post --allow-errors --headers { Authorization: $"Bearer ($token)", Content-Type: application/json } --content-type application/json $"($api)my/($name)/action/($action)" $data
  match $resp {
    {data: $data} => $data
    {error: $error} => {
      match ($error.code) {
        490 => "DoNothing"
        499 => {
          sleep ($error.message | parse --regex '(?P<cooldown>\d+(?:\.\d*)?)' | get 0 | get cooldown | into duration --unit sec)
          act $name $action $data
        }
        _ => {
          println $error
          $error
        }
      }
    }
  }
}
