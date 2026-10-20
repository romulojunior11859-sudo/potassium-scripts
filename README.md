# potassium-scripts

Scripts para executor Roblox (Potassium), jogo MineGame (PlaceId 79389059854988).

## minebot.lua
Automacao de jogabilidade: minerar, coletar bau, vender e equipar o melhor.
Usa os mesmos eventos que o cliente do jogo dispara (HitBreakable, HarvestSwing,
MineTakeChest, MineSellItems, MineEquipBest). Painel com RightShift.

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/romulojunior11859-sudo/potassium-scripts/main/minebot.lua"))()
```

## passpreview.lua
Faz o cliente local exibir a UI como se as gamepasses fossem suas. Serve para ver
como o jogo fica para quem comprou. Nao concede nada: o servidor roda a propria
checagem de posse.

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/romulojunior11859-sudo/potassium-scripts/main/passpreview.lua"))()
```
