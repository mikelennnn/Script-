--[[
  VAGABUNDO IA · Roblox (v6)
  - NUEVA pestaña "📌 Recordar": notas permanentes (solo se borran si tú quieres)
  - Escribe @ en cualquier caja de texto y sale la lista de jugadores del servidor
    (Recordar, Situación, Ubicación, Decir, Memoria y "Modificar")
  - Pellizca el panel con dos dedos para hacerlo más pequeño o grande
  - Anti-repetición + memoria con ASUNTOS ABIERTOS / CERRADOS
  - Filtro previo (izquierda) y respuestas pendientes (derecha)
  Tecla PC: RightShift = mostrar/ocultar panel
]]

local Players         = game:GetService("Players")
local HttpService     = game:GetService("HttpService")
local UIS             = game:GetService("UserInputService")
local GuiService      = game:GetService("GuiService")
local TextChatService = game:GetService("TextChatService")
local RS              = game:GetService("ReplicatedStorage")
local LP              = Players.LocalPlayer

local DEFAULT_KEY = "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"

local CONFIG = {
	MODEL   = "openai/gpt-oss-20b",
	URL     = "https://api.groq.com/openai/v1/chat/completions",
	RADIUS  = 20,
	MAX_CHARS = 150,
	MAX_LIST  = 10,
	MSG_WINDOW = 12,
	SUMMARY_AFTER = 12,
	SUMMARY_CHUNK = 6,
	TIMELINE = 8,
	PREV_CTX = 3,
	STALE = 20,
	ASK_EVERY = 4,
	MAX_TOKENS = 500,
	NOTES_CHARS = 1400, -- máximo de texto de notas que se manda a la IA por respuesta
	MAX_NOTE = 300,     -- largo máximo de cada nota
	MIN_SCALE = 0.55,
	MAX_SCALE = 1.8,
	DATA_VERSION = 5,   -- igual que antes: tu memoria actual NO se borra
	FILE = "VagabundoIA_memoria.json",
}

local env = (getgenv and getgenv()) or _G
if env.__VagabundoIA then pcall(env.__VagabundoIA) end

--// ============ ESTADO ============
local S = {
	enabled = true, approval = true, gate = true, sinceAsk = 0,
	apiKey = DEFAULT_KEY, effort = "low",
	scales = { main = 1, gate = 1, reply = 1 },
	sit = {}, loc = {}, users = {}, timeline = {}, notes = {},
}
local alive, dirty = true, false
local conns, queue = {}, {}
local usedTokens = 0
local wipedAtStart = false
local addFeed = function() end
local createCard, createGateCard

local function now() return os.time() end
local function trim(s) return (s:gsub("^%s*(.-)%s*$", "%1")) end
local function rel(t)
	local s = now() - (t or now())
	if s < 60 then return "hace segundos" end
	if s < 3600 then return "hace " .. math.floor(s / 60) .. " min" end
	if s < 86400 then return "hace " .. math.floor(s / 3600) .. " h" end
	return "hace " .. math.floor(s / 86400) .. " d"
end
local function maskKey(k) return k:sub(1, 8) .. "…" .. k:sub(-4) end

--// ============ PERSISTENCIA ============
local canFS = (writefile and readfile and isfile) and true or false
local function markDirty() dirty = true end
local function saveNow()
	if not canFS then return end
	pcall(function()
		writefile(CONFIG.FILE, HttpService:JSONEncode({
			v = CONFIG.DATA_VERSION,
			sit = S.sit, loc = S.loc, users = S.users, timeline = S.timeline, notes = S.notes,
			sinceAsk = S.sinceAsk, approval = S.approval, gate = S.gate,
			apiKey = S.apiKey, effort = S.effort, scales = S.scales,
		}))
	end)
	dirty = false
end
if canFS then
	pcall(function()
		if isfile(CONFIG.FILE) then
			local d = HttpService:JSONDecode(readfile(CONFIG.FILE))
			-- Ajustes y NOTAS: siempre se conservan
			S.approval = (d.approval ~= false)
			S.gate = (d.gate ~= false)
			S.apiKey = (type(d.apiKey) == "string" and d.apiKey ~= "") and d.apiKey or DEFAULT_KEY
			S.effort = (d.effort == "medium") and "medium" or "low"
			S.notes = (type(d.notes) == "table") and d.notes or {}
			if type(d.scales) == "table" then
				for k, v in pairs(d.scales) do
					if type(v) == "number" then S.scales[k] = math.clamp(v, CONFIG.MIN_SCALE, CONFIG.MAX_SCALE) end
				end
			end
			-- Memoria de conversaciones: solo si es de esta versión de datos
			if d.v == CONFIG.DATA_VERSION then
				S.sit, S.loc = d.sit or {}, d.loc or {}
				S.users, S.timeline = d.users or {}, d.timeline or {}
				S.sinceAsk = d.sinceAsk or 0
			else
				wipedAtStart = true
			end
		end
	end)
	if wipedAtStart then saveNow() end
end

--// ============ UTILIDADES DE MUNDO ============
local function hrp(p)
	local c = p and p.Character
	return c and c:FindFirstChild("HumanoidRootPart")
end
local function distTo(p)
	local a, b = hrp(LP), hrp(p)
	if a and b then return (a.Position - b.Position).Magnitude end
end
local function nearby()
	local list = {}
	for _, p in ipairs(Players:GetPlayers()) do
		if p ~= LP then
			local d = distTo(p)
			if d and d <= CONFIG.RADIUS then table.insert(list, { p = p, d = d }) end
		end
	end
	table.sort(list, function(a, b) return a.d < b.d end)
	return list
end

local function pushTimeline(kind, who, text)
	table.insert(S.timeline, { k = kind, w = who or "", t = text, ts = now() })
	while #S.timeline > CONFIG.TIMELINE do table.remove(S.timeline, 1) end
	markDirty()
end

local function getUser(p)
	local k = tostring(p.UserId)
	local u = S.users[k]
	if not u then
		u = { name = p.Name, display = p.DisplayName, first = now(), last = now(), n = 0, summary = "", msgs = {} }
		S.users[k] = u
	end
	u.name, u.display = p.Name, p.DisplayName
	u.msgs = u.msgs or {}
	u.summary = u.summary or ""
	u.n = u.n or 0
	return u, k
end

-- @menciones: busca al jugador por su nombre de usuario (en el servidor o en la memoria)
local function resolveName(name)
	local ln = name:lower()
	for _, p in ipairs(Players:GetPlayers()) do
		if p.Name:lower() == ln then return { name = p.Name, display = p.DisplayName, uid = p.UserId } end
	end
	for k, u in pairs(S.users) do
		if u.name and u.name:lower() == ln then
			return { name = u.name, display = u.display or u.name, uid = tonumber(k) }
		end
	end
	return nil
end
-- "@pedro123" -> "Pedro (@pedro123)" para que la IA sepa quién es
local function expandMentions(text)
	return (text:gsub("@([%w_]+)", function(n)
		local r = resolveName(n)
		if not r then return nil end
		if r.display == r.name then return "@" .. r.name end
		return r.display .. " (@" .. r.name .. ")"
	end))
end
-- Para texto que se dice en el chat: "@pedro123" -> "Pedro"
local function mentionsToDisplay(text)
	return (text:gsub("@([%w_]+)", function(n)
		local r = resolveName(n)
		return r and r.display or nil
	end))
end

--// ============ CHAT (enviar) ============
local function clip(s, n)
	local len = utf8.len(s)
	if not len then return s:sub(1, n) end
	if len <= n then return s end
	local cut = s:sub(1, utf8.offset(s, n + 1) - 1)
	local sp = cut:match("^(.*)%s%S*$")
	if sp and (utf8.len(sp) or 0) > n * 0.5 then return sp end
	return cut
end

local function sendChat(text)
	text = clip((text:gsub("^/+", "")), 195)
	if text == "" then return false end
	local ok = false
	if TextChatService.ChatVersion == Enum.ChatVersion.TextChatService then
		local chs = TextChatService:FindFirstChild("TextChannels")
		local ch = chs and chs:FindFirstChild("RBXGeneral")
		if ch then ok = pcall(function() ch:SendAsync(text) end) end
	else
		local ev = RS:FindFirstChild("DefaultChatSystemChatEvents")
		local say = ev and ev:FindFirstChild("SayMessageRequest")
		if say then ok = pcall(function() say:FireServer(text, "All") end) end
	end
	return ok
end

--// ============ API ============
local httpRequest = (syn and syn.request) or (http and http.request) or http_request or request or (fluxus and fluxus.request)

local function callAPI(messages, opts)
	opts = opts or {}
	if not httpRequest then return nil, "Tu ejecutor no soporta HTTP (request)" end
	local body = HttpService:JSONEncode({
		model = CONFIG.MODEL, messages = messages,
		temperature = opts.temp or 0.7, top_p = 0.95,
		max_completion_tokens = opts.max or CONFIG.MAX_TOKENS,
		reasoning_effort = opts.effort or S.effort,
	})
	for attempt = 1, 2 do
		local ok, res = pcall(httpRequest, {
			Url = CONFIG.URL, Method = "POST",
			Headers = { ["Content-Type"] = "application/json", ["Authorization"] = "Bearer " .. S.apiKey },
			Body = body,
		})
		if not ok or not res then return nil, "Fallo de red" end
		if res.StatusCode == 429 and attempt == 1 then
			task.wait(4)
		elseif res.StatusCode == 401 then
			return nil, "Clave API inválida (401)"
		elseif res.StatusCode ~= 200 then
			return nil, "HTTP " .. tostring(res.StatusCode)
		else
			local okd, j = pcall(HttpService.JSONDecode, HttpService, res.Body)
			if okd and j.usage and j.usage.total_tokens then usedTokens = usedTokens + j.usage.total_tokens end
			local txt = okd and j.choices and j.choices[1] and j.choices[1].message and j.choices[1].message.content
			if txt and txt ~= "" then return trim(txt) end
			return nil, "Respuesta vacía"
		end
	end
	return nil, "Límite de uso (429)"
end

local function cleanReply(s)
	s = s:gsub("[\r\n]+", " ")
	s = s:gsub("^%[[^%]]*%]:?%s*", "")
	s = s:gsub("%*%*", "*")
	s = trim(s)
	s = s:gsub('^"(.*)"$', "%1")
	return s
end

local function looksLikeAsk(s)
	s = s:lower()
	for _, w in ipairs({ "lana", "dinero", "moneda", "plata", "limosna", "feria", "billete", "centavo", "robux", "algo de comer", "comida", "un cambio" }) do
		if s:find(w, 1, true) then return true end
	end
	return false
end

-- Pista gratis (sin tokens): qué tipo de mensaje es
local function hint(t)
	local s = t:lower()
	local function has(...)
		for _, w in ipairs({ ... }) do if s:find(w, 1, true) then return true end end
		return false
	end
	if has("te puedo", "te ayudo", "te ofrezco", "te propongo", "trabajo", "pobreza", "quieres ganar", "te invito", "un trato") then
		return "Es una OFERTA o propuesta: muestra interés o desconfianza y pregunta de qué se trata o cuál es el truco. NO pidas dinero."
	end
	if has("toma ", "te regalo", "te doy", "aquí tienes", "para ti") then
		return "Te ofrece o da algo: reacciona a eso y agradece a tu manera."
	end
	if has("apestas", "lárgate", "largate", "vete ", "asqueroso", "inútil", "muérete", "sucio") then
		return "Es un insulto o rechazo: reacciona con orgullo, ironía o queja."
	end
	if has("sígueme", "sigueme", "ven ", "acompáñame", "acompaname", "vamos") then
		return "Te pide que lo acompañes o vayas: decide si aceptas y da un motivo."
	end
	if s:find("?", 1, true) or has("qué ", "que ", "cómo", "como ", "dónde", "donde", "cuándo", "quién", "quien", "por qué", "cuánto") then
		return "Es una pregunta: respóndela de verdad y con datos de tu situación."
	end
	if has("hola", "buenas", "qué tal", "hey", "ey ") then
		return "Es un saludo: saluda corto y con carácter."
	end
	return nil
end

--// ============ ANTI-REPETICIÓN (gratis, sin tokens) ============
local STOP = {}
for w in ("porque aunque entonces también tengo tienes tiene estoy estás están estaba hacer hacia puedo puedes quiero quieres sobre ahora aquí nada todo todos mucho mucha bueno buena parece después antes siempre nunca había hasta desde entre donde cuando quién cuál cómo vamos claro pues"):gmatch("%S+") do
	STOP[w] = true
end
local function words(s)
	local t = {}
	for w in s:lower():gmatch("[%w\128-\255]+") do
		if #w >= 5 and not STOP[w] then t[w] = true end
	end
	return t
end
local function recentAI(n)
	local list = {}
	for i = #S.timeline, 1, -1 do
		local e = S.timeline[i]
		if e.k == "ai" then
			table.insert(list, e.t)
			if #list >= n then break end
		end
	end
	return list
end
local function bannedWords(playerText)
	local rec = recentAI(3)
	if #rec < 2 then return {} end
	local count, pw = {}, words(playerText)
	for _, r in ipairs(rec) do
		for w in pairs(words(r)) do count[w] = (count[w] or 0) + 1 end
	end
	local out = {}
	for w, c in pairs(count) do
		if c >= 2 and not pw[w] then table.insert(out, w) end
	end
	table.sort(out)
	while #out > 5 do table.remove(out) end
	return out
end
local function usesBanned(out, banned)
	local ow, hit = words(out), {}
	for _, w in ipairs(banned) do if ow[w] then table.insert(hit, w) end end
	return hit
end

--// ============ PROMPT (compacto) ============
local PERSONA = [[
Eres un VAGABUNDO callejero en un juego de rol. Hablas como una persona real, nunca como asistente.
PERSONAJE: ropa rota, voz ronca, desconfiado, humor ácido, corazón noble. Jerga callejera suave, sin groserías fuertes. Solo pides dinero o comida si el PERMISO del final dice SÍ. Si te dan algo, lo agradeces y lo recuerdas.
REGLAS:
1. Responde al CONTENIDO concreto del último mensaje: pregunta -> la respondes; insulto -> reaccionas; saludo -> saludo corto; regalo -> agradeces; petición u orden -> aceptas, dudas o te niegas con un motivo; oferta, trato o ayuda -> interés o desconfianza y preguntas de qué se trata o cuál es el truco (NUNCA pidas dinero ante una oferta).
2. Añade algo concreto que haga avanzar la charla (una duda, una condición, un dato de tu vida). Nada de frases vacías ni fuera de lugar.
3. SITUACIÓN y UBICACIÓN se toman LITERALMENTE. La ubicación solo dice dónde estás: NO implica que estés enfermo, herido o asustado (en un hospital caminando eres un vagabundo que anda por ahí). Tu estado solo cambia si la situación lo dice expresamente. Si es grave (secuestro, pelea, policía, herido) manda sobre tu rutina y no pides dinero. La situación condiciona tu actitud, pero NO la menciones en cada respuesta: solo cuando venga al caso. Las "anteriores" ya pasaron. Si no puedes hablar (amordazado), solo sonidos o acciones.
4. MEMORIA: úsala solo cuando venga al caso. Lo de ABIERTO solo lo mencionas si el jugador toca el tema; lo resuelto o dejado atrás está CERRADO y no se retoma. Si el jugador cambia de tema, cambias con él: nunca vuelvas por tu cuenta a un tema anterior ni preguntes otra vez por algo ya tratado. Si pasó tiempo desde la última charla, lo anterior quedó atrás.
5. VARIEDAD: no repitas palabras, muletillas, preguntas ni estructura de tus respuestas recientes, y no empieces igual. Si FOCO prohíbe palabras, no las uses.
6. No inventes personas, objetos ni hechos que no consten; lo que ya dijiste es verdad. No saludes de nuevo si hablaron hace poco.
7. Contesta solo al jugador que te habla ahora. Los mensajes [NARRADOR] son órdenes o datos del mundo: obedécelos, no los respondas.
8. Nunca menciones IA, Roblox, narrador, memoria ni contexto.
9. NOTAS PERMANENTES: son hechos fijos del mundo. Tómalas como verdad, úsalas solo cuando vengan al caso y nunca las contradigas ni las recites sin motivo. Un nombre como Pedro (@pedro123) es el jugador de Roblox con ese nombre de usuario.
FORMATO: acciones entre *asteriscos*, diálogo sin comillas, sin emojis ni listas. 1 o 2 frases, máximo {MAX} caracteres. Si el jugador termina su mensaje con "/" es fuera de rol: responde breve, sin personaje, y termina con "/". Idioma del jugador (por defecto español).
ESTILO (no copiar):
- "Te puedo sacar de la pobreza" -> *te mira de arriba abajo* ¿Ah sí? ¿Y cuál es el truco? ¿Qué tendría que hacer?
- "Toma 50 robux" -> *abre los ojos como platos* ¡Dios te lo pague, no olvido a quien me ayuda!
- "¿Qué haces aquí?" -> Descansando, jefe, la calle no tiene horario. ¿Y tú, de paseo?
]]

-- Notas permanentes relevantes: generales + las que etiquetan a quien habla, a quien está cerca
-- o a quien se nombra en el mensaje. Así no se gastan tokens en notas que no vienen al caso.
local function notesBlock(plr, near, msgText)
	if #S.notes == 0 then return "" end
	local msgL = (msgText or ""):lower()
	local presence = {}
	if plr then presence[plr.UserId] = 3 end
	for _, e in ipairs(near or {}) do
		if not presence[e.p.UserId] then presence[e.p.UserId] = 2 end
	end
	local scored = {}
	for idx, n in ipairs(S.notes) do
		local ids, msgHit = {}, false
		for _, id in ipairs(n.uids or {}) do ids[id] = true end
		for nm in n.text:gmatch("@([%w_]+)") do
			local r = resolveName(nm)
			if r then
				ids[r.uid] = true
				if msgL:find(r.name:lower(), 1, true) or msgL:find((r.display or ""):lower(), 1, true) then
					msgHit = true
				end
			end
		end
		local pr = 0
		if not next(ids) then
			pr = 1 -- nota general (sin etiquetas válidas): siempre
		else
			for id in pairs(ids) do
				local v = presence[id]
				if v and v > pr then pr = v end
			end
			if msgHit and pr < 2 then pr = 2 end
		end
		if pr > 0 then table.insert(scored, { n = n, pr = pr, i = idx }) end
	end
	table.sort(scored, function(a, b)
		if a.pr ~= b.pr then return a.pr > b.pr end
		return a.i > b.i
	end)
	local lines, used = {}, 0
	for _, s in ipairs(scored) do
		local line = "- " .. expandMentions(s.n.text)
		if used + #line > CONFIG.NOTES_CHARS then break end
		used = used + #line
		table.insert(lines, line)
	end
	if #lines == 0 then return "" end
	return "NOTAS PERMANENTES (verdades fijas, siempre vigentes):\n" .. table.concat(lines, "\n")
end

local function buildSystem(plr, u, near, allowAsk, hintText, banned, msgText)
	local function curLine(a, empty)
		local x = a[1]
		if not x or x.ended then return empty end
		return expandMentions(x.text) .. " (puesta " .. rel(x.ts) .. ")"
	end
	local function prevLine(a, from)
		local t = {}
		for i = from, math.min(#a, from + CONFIG.PREV_CTX - 1) do table.insert(t, expandMentions(a[i].text)) end
		return #t > 0 and (" | ya pasaron: " .. table.concat(t, " | ")) or ""
	end
	local names = {}
	for _, e in ipairs(near) do
		table.insert(names, e.p.DisplayName .. " (@" .. e.p.Name .. ") " .. math.floor(e.d) .. " studs")
	end
	local tl = {}
	for _, e in ipairs(S.timeline) do
		if e.k == "say" then table.insert(tl, e.w .. ": " .. e.t)
		elseif e.k == "ai" then table.insert(tl, "TÚ a " .. e.w .. ": " .. e.t)
		elseif e.k == "sit" then table.insert(tl, "[NARRADOR] nueva situación: " .. expandMentions(e.t))
		elseif e.k == "end" then table.insert(tl, "[NARRADOR] terminó la situación: " .. expandMentions(e.t))
		else table.insert(tl, "[NARRADOR] nueva ubicación: " .. expandMentions(e.t)) end
	end

	local who = ""
	if plr and u then
		who = "HABLA AHORA: " .. u.display .. " (@" .. u.name .. ", a " .. math.floor(distTo(plr) or 0) .. " studs). "
		who = who .. (u.n == 0 and "Es la primera vez que hablan."
			or ("Han hablado " .. u.n .. " veces, la última " .. rel(u.last) .. "."))
		if u.n > 0 and now() - u.last > 300 then
			who = who .. " Ha pasado tiempo: lo de antes quedó atrás, no lo retomes salvo que él lo haga."
		end
		if u.summary ~= "" then who = who .. "\nFICHA DE ESTA PERSONA:\n" .. u.summary end
	end

	local sitFrom = (S.sit[1] and S.sit[1].ended) and 1 or 2
	local world = "MUNDO:\n- Situación actual: " .. curLine(S.sit, "ninguna especial") .. prevLine(S.sit, sitFrom)
		.. "\n- Ubicación actual: " .. curLine(S.loc, "una calle cualquiera") .. prevLine(S.loc, 2)
		.. "\n- Cerca: " .. (#names > 0 and table.concat(names, ", ") or "nadie")
	if #tl > 0 then world = world .. "\nHACE POCO:\n" .. table.concat(tl, "\n") end

	local nb = notesBlock(plr, near, msgText)
	if nb ~= "" then world = world .. "\n\n" .. nb end

	local tail = "\n\n" .. who
	local focus = {}
	if hintText then table.insert(focus, hintText) end
	if banned and #banned > 0 then
		table.insert(focus, "NO uses estas palabras en esta respuesta (ya las repetiste): " .. table.concat(banned, ", ") .. ". Habla solo de lo que dijo el jugador.")
	end
	if #focus > 0 then tail = tail .. "\nFOCO: " .. table.concat(focus, " ") end
	tail = tail .. "\nPERMISO PARA PEDIR DINERO/COMIDA: " .. (allowAsk and "SÍ, solo si encaja con lo que dicen" or "NO")

	return (PERSONA:gsub("{MAX}", tostring(CONFIG.MAX_CHARS))) .. "\n" .. world .. tail
end

--// ============ RESUMEN → FICHA (memoria larga por usuario) ============
local summarizing = {}
local function maybeSummarize(u)
	if summarizing[u] or #u.msgs <= CONFIG.SUMMARY_AFTER then return end
	summarizing[u] = true
	task.spawn(function()
		local lines, rest = {}, {}
		for i = 1, CONFIG.SUMMARY_CHUNK do
			local m = u.msgs[i]
			if m then table.insert(lines, (m.r == "u" and u.display or "Vagabundo") .. ": " .. m.t) end
		end
		for i = CONFIG.SUMMARY_CHUNK + 1, math.min(#u.msgs, CONFIG.SUMMARY_CHUNK + 6) do
			local m = u.msgs[i]
			table.insert(rest, (m.r == "u" and u.display or "Vagabundo") .. ": " .. m.t)
		end
		local out = callAPI({
			{ role = "system", content = "Archivista de un juego de rol. Actualiza la ficha de UNA persona que habla con un vagabundo. Formato exacto, máximo 750 caracteres:\nHECHOS: viñetas con lo duradero (nombre o apodo, dinero o comida dados o pedidos con cantidades, deudas, promesas cumplidas o rotas, datos que contó de sí, eventos importantes, lugares).\nRELACIÓN: una línea (cómo se tratan: amable, hostil, desconfianza...).\nABIERTO: solo asuntos realmente pendientes y vigentes (ofertas sin responder, citas, deudas por pagar). Si algo se resolvió, se rechazó, se dejó de mencionar o ya no importa, BÓRRALO de ABIERTO. Si no hay nada, escribe 'nada'.\nResponde solo con la ficha." },
			{ role = "user", content = "PERSONA: " .. u.display .. "\nFICHA ACTUAL:\n" .. (u.summary ~= "" and u.summary or "(vacía)") .. "\n\nNUEVOS MENSAJES A INCORPORAR:\n" .. table.concat(lines, "\n") .. "\n\nCONVERSACIÓN POSTERIOR (ya no se resume; úsala para saber qué sigue vigente):\n" .. (#rest > 0 and table.concat(rest, "\n") or "(nada)") .. "\n\nFicha actualizada:" },
		}, { temp = 0.2, max = 450, effort = "low" })
		if out then
			u.summary = out:sub(1, 1000)
			for _ = 1, CONFIG.SUMMARY_CHUNK do table.remove(u.msgs, 1) end
			markDirty()
		end
		summarizing[u] = nil
	end)
end

--// ============ GENERAR / ENVIAR RESPUESTAS ============
local PURPLE = Color3.fromRGB(196, 181, 253)

local function chatMessages(plr, u, text)
	local allow = (S.sinceAsk or 0) >= CONFIG.ASK_EVERY
	local msgs = { { role = "system", content = buildSystem(plr, u, nearby(), allow, hint(text), bannedWords(text), text) } }
	local from = math.max(1, #u.msgs - CONFIG.MSG_WINDOW + 1)
	for i = from, #u.msgs do
		local m = u.msgs[i]
		if m.r == "u" then
			table.insert(msgs, { role = "user", content = "[" .. u.display .. "]: " .. m.t })
		else
			table.insert(msgs, { role = "assistant", content = m.t })
		end
	end
	table.insert(msgs, { role = "user", content = "[" .. u.display .. "]: " .. text })
	return msgs
end

-- SOLO aquí se guarda en memoria (cuando tú envías). Lo rechazado nunca llega aquí.
local function commitReply(plr, text, out)
	local u = getUser(plr)
	sendChat(out)
	addFeed("🧥 " .. out, PURPLE)
	u.n = u.n + 1
	u.last = now()
	table.insert(u.msgs, { r = "u", t = text })
	table.insert(u.msgs, { r = "a", t = out })
	pushTimeline("say", u.display, text)
	pushTimeline("ai", u.display, out)
	S.sinceAsk = looksLikeAsk(out) and 0 or ((S.sinceAsk or 0) + 1)
	markDirty()
	maybeSummarize(u)
end

local function regenerate(plr, text, prevOut, instruction)
	local u = getUser(plr)
	local msgs = chatMessages(plr, u, text)
	table.insert(msgs, { role = "assistant", content = prevOut })
	table.insert(msgs, { role = "user", content = "[NARRADOR · Corrección]: Reescribe tu última respuesta aplicando este cambio: " .. instruction .. ". Sigue en personaje, mismo formato, máximo " .. CONFIG.MAX_CHARS .. " caracteres. Responde solo con la nueva respuesta." })
	local out, err = callAPI(msgs)
	if not out then return nil, err end
	out = cleanReply(out)
	if out == "" then return nil, "Respuesta vacía" end
	return out
end

local function handleChat(item)
	if not S.enabled then return end
	local plr, text = item.p, item.t
	local u = getUser(plr)
	local out, err = callAPI(chatMessages(plr, u, text))
	if not out then addFeed("⚠ " .. tostring(err), Color3.fromRGB(255, 138, 155)) return end
	out = cleanReply(out)
	if out == "" then return end

	local hit = usesBanned(out, bannedWords(text))
	if #hit > 0 then
		local out2 = regenerate(plr, text, out, "no uses las palabras: " .. table.concat(hit, ", ") .. ". Responde solo a lo que acaba de decir el jugador, sin retomar temas anteriores")
		if out2 then out = out2 end
	end

	if S.approval then
		createCard(plr, text, out)
	else
		task.wait(math.min(#out * 0.02, 2))
		commitReply(plr, text, out)
	end
end

local function handleSay(item)
	local raw = expandMentions(item.t)
	local msgs = {
		{ role = "system", content = buildSystem(nil, nil, nearby(), true, nil, bannedWords(""), raw) },
		{ role = "user", content = "[NARRADOR · Orden]: Tu personaje dice ahora en voz alta lo siguiente, a su manera de hablar, sin cambiar el significado, en 1 o 2 frases: " .. raw },
	}
	local out, err = callAPI(msgs)
	if not out then addFeed("⚠ " .. tostring(err), Color3.fromRGB(255, 138, 155)) return end
	out = cleanReply(out)
	if out == "" then return end
	sendChat(out)
	addFeed("🧥 " .. out, PURPLE)
	pushTimeline("ai", "todos", out)
end

local function enqueue(item)
	item.ts = now()
	table.insert(queue, item)
	while #queue > 6 do table.remove(queue, 1) end
end

task.spawn(function()
	while alive do
		local item = table.remove(queue, 1)
		if item then
			if now() - item.ts <= CONFIG.STALE then
				pcall(item.kind == "say" and handleSay or handleChat, item)
			end
			task.wait(1.3)
		else
			task.wait(0.2)
		end
	end
end)

local lastSeen = {}
local function onChat(plr, text)
	if plr == LP or not S.enabled or not text then return end
	text = trim(text)
	if #text < 2 or text:sub(1, 1) == "/" then return end
	local d = distTo(plr)
	if not d or d > CONFIG.RADIUS then return end
	local ls = lastSeen[plr.UserId]
	if ls and ls.t == text and now() - ls.ts < 15 then return end
	lastSeen[plr.UserId] = { t = text, ts = now() }
	addFeed(plr.DisplayName .. ": " .. text)
	if S.gate then
		createGateCard(plr, text)
	else
		enqueue({ kind = "chat", p = plr, t = text })
	end
end

if TextChatService.ChatVersion == Enum.ChatVersion.TextChatService then
	table.insert(conns, TextChatService.MessageReceived:Connect(function(m)
		local src = m.TextSource
		if not src then return end
		local plr = Players:GetPlayerByUserId(src.UserId)
		if plr then onChat(plr, m.Text) end
	end))
else
	local function hook(p) table.insert(conns, p.Chatted:Connect(function(msg) onChat(p, msg) end)) end
	for _, p in ipairs(Players:GetPlayers()) do hook(p) end
	table.insert(conns, Players.PlayerAdded:Connect(hook))
end

--// ============ GUI: utilidades ============
local C = {
	bg = Color3.fromRGB(11, 13, 18), panel = Color3.fromRGB(18, 21, 28), panel2 = Color3.fromRGB(28, 32, 44),
	line = Color3.fromRGB(40, 46, 62), txt = Color3.fromRGB(232, 234, 240), mute = Color3.fromRGB(139, 147, 167),
	acc = Color3.fromRGB(124, 92, 255), acc2 = Color3.fromRGB(79, 209, 197),
	warn = Color3.fromRGB(251, 191, 36), red = Color3.fromRGB(255, 138, 155),
}

local function new(class, props, parent)
	local o = Instance.new(class)
	for k, v in pairs(props or {}) do o[k] = v end
	if parent then o.Parent = parent end
	return o
end
local function corner(o, r) new("UICorner", { CornerRadius = UDim.new(0, r or 8) }, o) return o end
local function stroke(o, c) new("UIStroke", { Color = c or C.line, Thickness = 1, ApplyStrokeMode = Enum.ApplyStrokeMode.Border }, o) return o end
local function frame(parent, props)
	local p = { BackgroundColor3 = C.panel, BorderSizePixel = 0 }
	for k, v in pairs(props or {}) do p[k] = v end
	return new("Frame", p, parent)
end
local function label(parent, text, props)
	local p = { Text = text, BackgroundTransparency = 1, Font = Enum.Font.Gotham, TextSize = 12, TextColor3 = C.mute, TextXAlignment = Enum.TextXAlignment.Left, TextWrapped = true }
	for k, v in pairs(props or {}) do p[k] = v end
	return new("TextLabel", p, parent)
end
local function btn(parent, text, props, cb)
	local p = { Text = text, Font = Enum.Font.GothamBold, TextSize = 12, TextColor3 = C.txt, BackgroundColor3 = C.panel2, BorderSizePixel = 0, AutoButtonColor = true }
	for k, v in pairs(props or {}) do p[k] = v end
	local b = corner(new("TextButton", p, parent), 8)
	if cb then b.Activated:Connect(cb) end
	return b
end
local function textbox(parent, ph, props)
	local p = { PlaceholderText = ph, Text = "", ClearTextOnFocus = false, Font = Enum.Font.Gotham, TextSize = 13, TextColor3 = C.txt, PlaceholderColor3 = C.mute, BackgroundColor3 = C.bg, BorderSizePixel = 0, TextXAlignment = Enum.TextXAlignment.Left, ClipsDescendants = true }
	for k, v in pairs(props or {}) do p[k] = v end
	local t = stroke(corner(new("TextBox", p, parent), 8))
	new("UIPadding", { PaddingLeft = UDim.new(0, 8), PaddingRight = UDim.new(0, 8) }, t)
	return t
end
local function scroller(parent, props)
	local p = { BackgroundColor3 = C.bg, BorderSizePixel = 0, ScrollBarThickness = 3, CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.Y }
	for k, v in pairs(props or {}) do p[k] = v end
	local s = corner(new("ScrollingFrame", p, parent), 8)
	new("UIListLayout", { Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder }, s)
	new("UIPadding", { PaddingTop = UDim.new(0, 4), PaddingLeft = UDim.new(0, 4), PaddingRight = UDim.new(0, 4), PaddingBottom = UDim.new(0, 4) }, s)
	return s
end

local function guiParent()
	local ok, h = pcall(function() return gethui and gethui() end)
	if ok and h then return h end
	local ok2, cg = pcall(function() return game:GetService("CoreGui") end)
	if ok2 and cg then return cg end
	return LP:WaitForChild("PlayerGui")
end

local gui = new("ScreenGui", { Name = "VagabundoIA", ResetOnSpawn = false, IgnoreGuiInset = true, DisplayOrder = 999, ZIndexBehavior = Enum.ZIndexBehavior.Sibling })
pcall(function() if syn and syn.protect_gui then syn.protect_gui(gui) end end)
gui.Parent = guiParent()

-- Posicionar usando Scale (así UIScale no descuadra las posiciones)
local function placeAbs(target, x, y)
	local vs = gui.AbsoluteSize
	if vs.X <= 0 or vs.Y <= 0 then return end
	target.Position = UDim2.fromScale(x / vs.X, y / vs.Y)
end
local function keepOnScreen(root)
	local vs, sz, p = gui.AbsoluteSize, root.AbsoluteSize, root.AbsolutePosition
	placeAbs(root, math.clamp(p.X, 0, math.max(0, vs.X - sz.X)), math.clamp(p.Y, 0, math.max(0, vs.Y - sz.Y)))
end

local function makeDraggable(handle, target, onTap)
	local dragging, moved, start, startAbs = false, false, nil, nil
	handle.InputBegan:Connect(function(i)
		if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
			dragging, moved = true, false
			start, startAbs = i.Position, target.AbsolutePosition
			i.Changed:Connect(function()
				if i.UserInputState == Enum.UserInputState.End then
					dragging = false
					if not moved and onTap then onTap() end
				end
			end)
		end
	end)
	table.insert(conns, UIS.InputChanged:Connect(function(i)
		if dragging and (i.UserInputType == Enum.UserInputType.MouseMovement or i.UserInputType == Enum.UserInputType.Touch) then
			local d = i.Position - start
			if d.Magnitude > 6 then moved = true end
			local vs, sz = gui.AbsoluteSize, target.AbsoluteSize
			local x = math.clamp(startAbs.X + d.X, 0, math.max(0, vs.X - sz.X))
			local y = math.clamp(startAbs.Y + d.Y, 0, math.max(0, vs.Y - sz.Y))
			placeAbs(target, x, y)
		end
	end))
end

--// ============ @MENCIONES (lista de jugadores al escribir @) ============
local popup = stroke(corner(frame(gui, { Name = "Menciones", BackgroundColor3 = C.panel, Visible = false, ZIndex = 200, Size = UDim2.fromOffset(220, 40) }), 10), C.acc)
local popList = scroller(popup, { Size = UDim2.new(1, 0, 1, 0), BackgroundColor3 = C.panel })
local activeBox

local function hidePopup()
	popup.Visible = false
	activeBox = nil
end

local function candidates(q)
	local ql = q:lower()
	local out, seen = {}, {}
	for _, p in ipairs(Players:GetPlayers()) do
		local nl, dl = p.Name:lower(), p.DisplayName:lower()
		if ql == "" or nl:find(ql, 1, true) or dl:find(ql, 1, true) then
			seen[p.UserId] = true
			local d = 1e9
			if p == LP then d = 1.5e9 else d = distTo(p) or 1e9 end
			table.insert(out, { name = p.Name, display = p.DisplayName, online = true, me = (p == LP), d = d })
		end
	end
	for k, u in pairs(S.users) do
		local id = tonumber(k)
		if id and not seen[id] and u.name then
			local nl, dl = u.name:lower(), (u.display or ""):lower()
			if ql == "" or nl:find(ql, 1, true) or dl:find(ql, 1, true) then
				table.insert(out, { name = u.name, display = u.display or u.name, online = false, d = 2e9 })
			end
		end
	end
	table.sort(out, function(a, b)
		if a.d ~= b.d then return a.d < b.d end
		return a.name:lower() < b.name:lower()
	end)
	return out
end

local function insertMention(box, name)
	local text, cp = box.Text, box.CursorPosition
	local before, after = text, ""
	if cp and cp > 0 then before, after = text:sub(1, cp - 1), text:sub(cp) end
	local q = before:match("@([%w_]*)$") or ""
	before = before:sub(1, #before - #q - 1) .. "@" .. name .. " "
	local newCp = #before + 1
	box.Text = before .. after
	hidePopup()
	box:CaptureFocus()
	box.CursorPosition = math.min(newCp, #box.Text + 1)
end

local function updatePopup(box)
	local before, cp = box.Text, box.CursorPosition
	if cp and cp > 0 then before = box.Text:sub(1, cp - 1) end
	local q = before:match("@([%w_]*)$")
	if not q then hidePopup() return end
	local list = candidates(q)
	if #list == 0 then hidePopup() return end
	activeBox = box
	for _, c in ipairs(popList:GetChildren()) do if c:IsA("TextButton") then c:Destroy() end end
	local shown = math.min(#list, 8)
	for i = 1, shown do
		local it = list[i]
		local b = btn(popList, "@" .. it.name .. "  ·  " .. it.display .. (it.me and "  (tú)" or (it.online and "" or "  · fuera")), {
			Size = UDim2.new(1, -4, 0, 28), LayoutOrder = i, Font = Enum.Font.Gotham, TextSize = 12,
			TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd,
			TextColor3 = it.online and C.txt or C.mute,
		}, function() insertMention(box, it.name) end)
		new("UIPadding", { PaddingLeft = UDim.new(0, 8) }, b)
	end
	local ap, as, vs = box.AbsolutePosition, box.AbsoluteSize, gui.AbsoluteSize
	local h = math.min(shown * 32 + 10, 214)
	local w = math.max(as.X, 210)
	local x = math.clamp(ap.X, 0, math.max(0, vs.X - w))
	local y = ap.Y + as.Y + 2
	if y + h > vs.Y then y = math.max(0, ap.Y - h - 2) end
	popup.Size = UDim2.fromOffset(w, h)
	popup.Position = UDim2.fromOffset(x, y)
	popup.Visible = true
end

local function withMentions(box)
	box:GetPropertyChangedSignal("Text"):Connect(function() updatePopup(box) end)
	box:GetPropertyChangedSignal("CursorPosition"):Connect(function() if box:IsFocused() then updatePopup(box) end end)
	box.FocusLost:Connect(function()
		task.delay(0.6, function()
			if activeBox == box and not box:IsFocused() then hidePopup() end
		end)
	end)
	return box
end

-- Paneles que se pueden escalar (pellizco)
local scalables = {}
local function registerScalable(root, key)
	local us = new("UIScale", { Scale = S.scales[key] or 1 }, root)
	table.insert(scalables, { root = root, us = us, key = key })
	return us
end
local function applyScale(key, v)
	for _, sc in ipairs(scalables) do
		if sc.key == key then
			sc.us.Scale = math.clamp(v, CONFIG.MIN_SCALE, CONFIG.MAX_SCALE)
			S.scales[key] = sc.us.Scale
			keepOnScreen(sc.root)
			markDirty()
		end
	end
end

--// ============ GUI: panel principal ============
local FULL, MINI = UDim2.fromOffset(330, 420), UDim2.fromOffset(330, 38)
local main = stroke(corner(frame(gui, { Name = "Main", Size = FULL, Position = UDim2.new(0.5, -165, 0, 100), BackgroundColor3 = C.bg, ClipsDescendants = true }), 14))
registerScalable(main, "main")
local bar = corner(frame(main, { Size = UDim2.new(1, 0, 0, 38), Active = true }), 14)
frame(bar, { Position = UDim2.new(0, 0, 1, -14), Size = UDim2.new(1, 0, 0, 14) })
label(bar, "🧥  Vagabundo IA", { Font = Enum.Font.GothamBold, TextSize = 14, TextColor3 = C.txt, Position = UDim2.fromOffset(12, 0), Size = UDim2.new(1, -120, 1, 0), TextWrapped = false })
local body = frame(main, { Position = UDim2.fromOffset(0, 38), Size = UDim2.new(1, 0, 1, -38), BackgroundTransparency = 1 })
makeDraggable(bar, main)

local bubble = stroke(corner(new("TextButton", { Text = "🧥", TextSize = 22, Size = UDim2.fromOffset(46, 46), Position = UDim2.fromOffset(16, 100), BackgroundColor3 = C.panel, TextColor3 = C.txt, BorderSizePixel = 0, AutoButtonColor = false, Visible = false }, gui), 23))
local function showMain() main.Visible, bubble.Visible = true, false end
local function hideMain()
	bubble.Position = UDim2.fromOffset(main.AbsolutePosition.X, main.AbsolutePosition.Y)
	main.Visible, bubble.Visible = false, true
	hidePopup()
end
makeDraggable(bubble, bubble, showMain)

local minimized = false
btn(bar, "▾", { Size = UDim2.fromOffset(30, 26), Position = UDim2.new(1, -102, 0.5, -13), TextSize = 13 }, function()
	minimized = not minimized
	body.Visible = not minimized
	main.Size = minimized and MINI or FULL
	hidePopup()
end)
btn(bar, "◉", { Size = UDim2.fromOffset(30, 26), Position = UDim2.new(1, -68, 0.5, -13), TextSize = 13 }, hideMain)

local function cleanup()
	alive = false
	for _, c in ipairs(conns) do pcall(function() c:Disconnect() end) end
	saveNow()
	pcall(function() gui:Destroy() end)
	env.__VagabundoIA = nil
end
env.__VagabundoIA = cleanup
btn(bar, "✕", { Size = UDim2.fromOffset(30, 26), Position = UDim2.new(1, -34, 0.5, -13), TextSize = 13, TextColor3 = C.red }, cleanup)

table.insert(conns, UIS.InputBegan:Connect(function(i, gp)
	if not gp and i.KeyCode == Enum.KeyCode.RightShift then
		if main.Visible then hideMain() else showMain() end
	end
end))

-- Pestañas (la barra se desliza de lado)
local pages, tabBtns = {}, {}
local TABS = {
	{ "home", "Inicio" }, { "sit", "⚡ Situación" }, { "loc", "📍 Ubicación" }, { "say", "💬 Decir" },
	{ "mem", "🧠 Memoria" }, { "rec", "📌 Recordar" }, { "cfg", "⚙ Ajustes" },
}
local renderMem
local tabRow = new("ScrollingFrame", {
	BackgroundTransparency = 1, BorderSizePixel = 0, Position = UDim2.fromOffset(6, 4), Size = UDim2.new(1, -12, 0, 30),
	ScrollBarThickness = 0, ScrollingDirection = Enum.ScrollingDirection.X,
	CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.X,
}, body)
new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder }, tabRow)

local function showPage(name)
	for n, p in pairs(pages) do p.Visible = (n == name) end
	for n, b in pairs(tabBtns) do
		b.BackgroundColor3 = (n == name) and C.acc or C.panel2
		b.TextColor3 = (n == name) and Color3.new(1, 1, 1) or C.mute
	end
	local b = tabBtns[name]
	if b then
		local sc = S.scales.main or 1
		local left = b.AbsolutePosition.X - tabRow.AbsolutePosition.X
		local right = left + b.AbsoluteSize.X
		local view = tabRow.AbsoluteSize.X
		if left < 0 then
			tabRow.CanvasPosition = Vector2.new(math.max(0, tabRow.CanvasPosition.X + left / sc - 6), 0)
		elseif right > view then
			tabRow.CanvasPosition = Vector2.new(tabRow.CanvasPosition.X + (right - view) / sc + 6, 0)
		end
	end
	if name == "mem" then renderMem() end
	hidePopup()
end
for i, t in ipairs(TABS) do
	local b = btn(tabRow, t[2], { Size = UDim2.fromOffset(0, 28), AutomaticSize = Enum.AutomaticSize.X, TextSize = 11, LayoutOrder = i }, function() showPage(t[1]) end)
	new("UIPadding", { PaddingLeft = UDim.new(0, 10), PaddingRight = UDim.new(0, 10) }, b)
	tabBtns[t[1]] = b
	pages[t[1]] = frame(body, { BackgroundTransparency = 1, Position = UDim2.fromOffset(8, 40), Size = UDim2.new(1, -16, 1, -48), Visible = false })
end

-- ---------- INICIO ----------
local home = pages.home
local function makeToggle(text, y, key, onT, offT)
	label(home, text, { Font = Enum.Font.GothamBold, TextSize = 12, TextColor3 = C.txt, Position = UDim2.fromOffset(0, y), Size = UDim2.new(1, -100, 0, 28) })
	local b
	local function paint()
		b.Text = S[key] and onT or offT
		b.BackgroundColor3 = S[key] and C.acc2 or C.panel2
		b.TextColor3 = S[key] and C.bg or C.mute
	end
	b = btn(home, "", { Size = UDim2.fromOffset(92, 26), Position = UDim2.new(1, -92, 0, y + 1), TextSize = 11 }, function()
		S[key] = not S[key]
		paint()
		if key == "enabled" and not S.enabled then table.clear(queue) end
		markDirty()
	end)
	paint()
end
makeToggle("IA del vagabundo", 0, "enabled", "ACTIVA", "PAUSADA")
makeToggle("Aprobar respuestas (derecha)", 30, "approval", "SÍ", "NO (auto)")
makeToggle("Filtro previo (izquierda)", 60, "gate", "SÍ", "NO (auto)")

local nearLabel = label(home, "", { Position = UDim2.fromOffset(0, 92), Size = UDim2.new(1, 0, 0, 34), TextSize = 11 })
local feedSF = scroller(home, { Position = UDim2.fromOffset(0, 130), Size = UDim2.new(1, 0, 1, -168) })
btn(home, "Cerrar script", { Position = UDim2.new(0, 0, 1, -30), Size = UDim2.new(1, 0, 0, 30), TextColor3 = C.red }, cleanup)

local feedCount = 0
addFeed = function(text, color)
	feedCount = feedCount + 1
	label(feedSF, text, { TextColor3 = color or C.txt, Size = UDim2.new(1, -6, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = feedCount })
	local kids = {}
	for _, c in ipairs(feedSF:GetChildren()) do if c:IsA("TextLabel") then table.insert(kids, c) end end
	if #kids > 40 then
		table.sort(kids, function(a, b) return a.LayoutOrder < b.LayoutOrder end)
		kids[1]:Destroy()
	end
	task.delay(0.05, function() if alive then feedSF.CanvasPosition = Vector2.new(0, 1e6) end end)
end

-- ---------- SITUACIÓN / UBICACIÓN ----------
local boxes, lists = {}, {}
local function renderList(kind)
	local sf = lists[kind]
	for _, c in ipairs(sf:GetChildren()) do if c:IsA("TextButton") then c:Destroy() end end
	for i, it in ipairs(S[kind]) do
		local current = (i == 1 and not it.ended)
		local b = btn(sf, (current and "● " or (it.ended and "✔ " or "")) .. it.text, {
			Size = UDim2.new(1, -4, 0, 30), LayoutOrder = i, Font = Enum.Font.Gotham, TextSize = 12,
			TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd,
			TextColor3 = current and C.acc2 or (it.ended and C.mute or C.txt),
		}, function() boxes[kind].Text = it.text end)
		new("UIPadding", { PaddingLeft = UDim.new(0, 8), PaddingRight = UDim.new(0, 8) }, b)
	end
end
local function addContext(kind, text)
	text = trim(text)
	if text == "" then return end
	table.insert(S[kind], 1, { text = text, ts = now() })
	while #S[kind] > CONFIG.MAX_LIST do table.remove(S[kind]) end
	pushTimeline(kind, "", text)
	addFeed((kind == "sit" and "⚡ Situación: " or "📍 Ubicación: ") .. text, C.warn)
	renderList(kind)
end
local function endSituation()
	local cur = S.sit[1]
	if not cur or cur.ended then return end
	cur.ended = true
	pushTimeline("end", "", cur.text)
	addFeed("🏁 Situación terminada: " .. cur.text, C.warn)
	renderList("sit")
	markDirty()
end
local function listPage(kind, ph, info, canEnd)
	local p = pages[kind]
	local y0 = canEnd and 32 or 0
	label(p, info, { Size = UDim2.new(1, 0, 0, 30), TextSize = 11 })
	boxes[kind] = withMentions(textbox(p, ph, { Position = UDim2.fromOffset(0, 34), Size = UDim2.new(1, -70, 0, 32) }))
	btn(p, "Enviar", { Position = UDim2.new(1, -64, 0, 34), Size = UDim2.fromOffset(64, 32), BackgroundColor3 = C.acc }, function()
		addContext(kind, boxes[kind].Text)
		boxes[kind].Text = ""
	end)
	if canEnd then
		btn(p, "🏁 Terminar situación actual", { Position = UDim2.fromOffset(0, 70), Size = UDim2.new(1, 0, 0, 28), TextColor3 = C.warn, TextSize = 11 }, endSituation)
	end
	label(p, "Últimas " .. CONFIG.MAX_LIST .. " (toca una para reutilizarla):", { Position = UDim2.fromOffset(0, 72 + y0), Size = UDim2.new(1, 0, 0, 16), TextSize = 10 })
	lists[kind] = scroller(p, { Position = UDim2.fromOffset(0, 92 + y0), Size = UDim2.new(1, 0, 1, -(92 + y0)) })
	renderList(kind)
end
listPage("sit", "Ej: Un policía le pide ID a @usuario", "Cuéntale qué pasa. Escribe @ para etiquetar a alguien. No responde nada; al terminar pulsa Terminar.", true)
listPage("loc", "Ej: Dentro de un hospital con @usuario", "Dile dónde está. Escribe @ para etiquetar a alguien. No responde nada.", false)

-- ---------- DECIR ----------
do
	local p = pages.say
	label(p, "Escribe lo que quieres que diga y lo dirá en el chat con su forma de hablar. Usa @ para etiquetar.", { Size = UDim2.new(1, 0, 0, 30), TextSize = 11 })
	local sayBox = withMentions(textbox(p, "Ej: Pregúntale su nombre a @usuario", { Position = UDim2.fromOffset(0, 34), Size = UDim2.new(1, 0, 0, 34) }))
	local literal = false
	local lit = btn(p, "☐  Texto exacto (sin adaptarlo, no gasta tokens)", { Position = UDim2.fromOffset(0, 76), Size = UDim2.new(1, 0, 0, 30), Font = Enum.Font.Gotham, TextColor3 = C.mute, TextXAlignment = Enum.TextXAlignment.Left, TextSize = 11 })
	new("UIPadding", { PaddingLeft = UDim.new(0, 8) }, lit)
	lit.Activated:Connect(function()
		literal = not literal
		lit.Text = (literal and "☑" or "☐") .. "  Texto exacto (sin adaptarlo, no gasta tokens)"
		lit.TextColor3 = literal and C.acc2 or C.mute
	end)
	btn(p, "Enviar", { Position = UDim2.fromOffset(0, 114), Size = UDim2.new(1, 0, 0, 34), BackgroundColor3 = C.acc }, function()
		local t = trim(sayBox.Text)
		if t == "" then return end
		sayBox.Text = ""
		addFeed("💬 Decir: " .. t, C.acc2)
		if literal then
			local exact = mentionsToDisplay(t) -- en el chat sale el nombre visible, sin @
			sendChat(exact)
			pushTimeline("ai", "todos", exact)
		else
			enqueue({ kind = "say", t = t })
		end
	end)
end

-- ---------- MEMORIA ----------
local recBox
do
	local p = pages.mem
	local selected
	local search = withMentions(textbox(p, "Buscar jugador o escribe @", { Size = UDim2.new(1, 0, 0, 28), TextSize = 12 }))
	local memList = scroller(p, { Position = UDim2.fromOffset(0, 32), Size = UDim2.new(1, 0, 0, 76) })
	local detail = scroller(p, { Position = UDim2.fromOffset(0, 112), Size = UDim2.new(1, 0, 1, -182) })
	local detailLbl = label(detail, "", { Size = UDim2.new(1, -6, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, TextColor3 = C.txt })

	local function renderDetail()
		local u = selected and S.users[selected]
		if not u then detailLbl.Text = "Toca un usuario (o búscalo con @) para ver su ficha." return end
		detailLbl.Text = u.display .. " (@" .. u.name .. ")\nMensajes: " .. u.n .. " · Última vez: " .. rel(u.last) ..
			"\n\nFicha:\n" .. (u.summary ~= "" and u.summary or "(aún sin ficha; se crea cuando la charla se alarga)")
	end
	local function filterQ()
		local q = trim(search.Text):lower()
		q = q:gsub("^@", "")
		return q
	end
	local function autoSelect()
		local nm = search.Text:match("^%s*@([%w_]+)%s")
		if not nm then return end
		local ln = nm:lower()
		for k, u in pairs(S.users) do
			if u.name and u.name:lower() == ln then selected = k return end
		end
	end
	renderMem = function()
		for _, c in ipairs(memList:GetChildren()) do if c:IsA("TextButton") then c:Destroy() end end
		local q = filterQ()
		local arr = {}
		for k, u in pairs(S.users) do
			if q == "" or (u.display or ""):lower():find(q, 1, true) or (u.name or ""):lower():find(q, 1, true) then
				table.insert(arr, { k = k, u = u })
			end
		end
		table.sort(arr, function(a, b) return (a.u.last or 0) > (b.u.last or 0) end)
		for i, e in ipairs(arr) do
			local b = btn(memList, e.u.display .. "  ·  " .. (e.u.n or 0) .. " msgs", {
				Size = UDim2.new(1, -4, 0, 28), LayoutOrder = i, Font = Enum.Font.Gotham,
				TextXAlignment = Enum.TextXAlignment.Left,
				TextColor3 = (e.k == selected) and C.acc2 or C.txt,
			}, function() selected = e.k renderMem() end)
			new("UIPadding", { PaddingLeft = UDim.new(0, 8) }, b)
		end
		renderDetail()
	end
	search:GetPropertyChangedSignal("Text"):Connect(function() autoSelect() renderMem() end)

	btn(p, "📌 Añadir nota sobre este usuario", { Position = UDim2.new(0, 0, 1, -66), Size = UDim2.new(1, 0, 0, 28), TextColor3 = C.acc2, TextSize = 11 }, function()
		local u = selected and S.users[selected]
		if not u then addFeed("Selecciona primero un usuario en Memoria", C.warn) return end
		showPage("rec")
		if recBox then
			recBox.Text = "@" .. u.name .. " "
			recBox:CaptureFocus()
		end
	end)

	local function confirmBtn(text, pos, size, action)
		local armed = false
		local b
		b = btn(p, text, { Position = pos, Size = size, TextColor3 = C.red, TextSize = 11 }, function()
			if not armed then
				armed = true
				b.Text = "¿Seguro? toca otra vez"
				task.delay(3, function() armed = false if b.Parent then b.Text = text end end)
			else
				armed = false
				b.Text = text
				action()
				renderMem()
			end
		end)
	end
	confirmBtn("Olvidar usuario", UDim2.new(0, 0, 1, -32), UDim2.new(0.5, -3, 0, 32), function()
		if selected then S.users[selected] = nil selected = nil markDirty() end
	end)
	confirmBtn("Borrar memoria", UDim2.new(0.5, 3, 1, -32), UDim2.new(0.5, -3, 0, 32), function()
		S.users, S.timeline, S.sit, S.loc, selected = {}, {}, {}, {}, nil
		S.sinceAsk = 0
		renderList("sit") renderList("loc") markDirty()
		addFeed("🧹 Memoria borrada (las notas de Recordar siguen intactas)", C.warn)
	end)
end

-- ---------- RECORDAR (notas permanentes) ----------
do
	local p = pages.rec
	label(p, "Dile qué debe recordar SIEMPRE. Escribe @ para etiquetar a un jugador. Nunca se borra solo.", { Size = UDim2.new(1, 0, 0, 30), TextSize = 11 })
	local box = withMentions(textbox(p, "Ej: @usuario es mi amigo y me debe 50 robux", {
		Position = UDim2.fromOffset(0, 34), Size = UDim2.new(1, 0, 0, 56), MultiLine = true, TextWrapped = true,
		TextYAlignment = Enum.TextYAlignment.Top, TextSize = 12,
	}))
	recBox = box
	local editing, save
	local count = label(p, "", { Position = UDim2.fromOffset(0, 130), Size = UDim2.new(1, 0, 0, 14), TextSize = 10 })
	local list = scroller(p, { Position = UDim2.fromOffset(0, 146), Size = UDim2.new(1, 0, 1, -184) })

	local function rich(s)
		s = s:gsub("&", "&amp;")
		s = s:gsub("<", "&lt;")
		s = s:gsub(">", "&gt;")
		s = s:gsub("@([%w_]+)", '<font color="#4fd1c5">@%1</font>')
		return s
	end

	local function renderNotes()
		for _, c in ipairs(list:GetChildren()) do if c:IsA("Frame") then c:Destroy() end end
		count.Text = #S.notes .. " nota(s) permanente(s) · toca una para editarla"
		for k = #S.notes, 1, -1 do
			local n = S.notes[k]
			local row = corner(frame(list, { BackgroundColor3 = C.panel2, Size = UDim2.new(1, -4, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = #S.notes - k }), 8)
			local t = new("TextButton", {
				Text = rich(n.text), RichText = true, TextWrapped = true, TextXAlignment = Enum.TextXAlignment.Left,
				TextYAlignment = Enum.TextYAlignment.Top, BackgroundTransparency = 1, Font = Enum.Font.Gotham, TextSize = 12,
				TextColor3 = C.txt, AutoButtonColor = false, Size = UDim2.new(1, -38, 0, 34), AutomaticSize = Enum.AutomaticSize.Y,
			}, row)
			new("UIPadding", { PaddingLeft = UDim.new(0, 8), PaddingTop = UDim.new(0, 6), PaddingBottom = UDim.new(0, 6), PaddingRight = UDim.new(0, 4) }, t)
			t.Activated:Connect(function()
				editing = n
				box.Text = n.text
				save.Text = "Actualizar"
				box:CaptureFocus()
			end)
			local armed = false
			local del
			del = btn(row, "🗑", { Size = UDim2.fromOffset(28, 28), Position = UDim2.new(1, -32, 0, 3), TextColor3 = C.red, TextSize = 13 }, function()
				if not armed then
					armed = true
					del.Text = "¿?"
					task.delay(3, function() armed = false if del.Parent then del.Text = "🗑" end end)
				else
					for idx, x in ipairs(S.notes) do
						if x == n then table.remove(S.notes, idx) break end
					end
					if editing == n then editing = nil box.Text = "" save.Text = "Guardar" end
					saveNow()
					renderNotes()
					addFeed("🗑 Nota eliminada", C.mute)
				end
			end)
		end
	end

	save = btn(p, "Guardar", { Position = UDim2.fromOffset(0, 96), Size = UDim2.new(0.6, -3, 0, 30), BackgroundColor3 = C.acc }, function()
		local t = trim((box.Text:gsub("[\r\n]+", " ")))
		if t == "" then return end
		t = clip(t, CONFIG.MAX_NOTE)
		local uids = {}
		for nm in t:gmatch("@([%w_]+)") do
			local r = resolveName(nm)
			if r then table.insert(uids, r.uid) end
		end
		if editing then
			editing.text, editing.uids = t, uids
		else
			table.insert(S.notes, { id = tostring(now()) .. tostring(math.random(1000, 9999)), text = t, ts = now(), uids = uids })
		end
		editing = nil
		box.Text = ""
		save.Text = "Guardar"
		saveNow()
		renderNotes()
		addFeed("📌 Nota guardada: " .. t, C.acc2)
	end)
	btn(p, "Cancelar", { Position = UDim2.new(0.6, 3, 0, 96), Size = UDim2.new(0.4, -3, 0, 30), TextSize = 11 }, function()
		editing = nil
		box.Text = ""
		save.Text = "Guardar"
	end)

	local armedAll = false
	local delAll
	delAll = btn(p, "Borrar todas las notas", { Position = UDim2.new(0, 0, 1, -32), Size = UDim2.new(1, 0, 0, 32), TextColor3 = C.red, TextSize = 11 }, function()
		if not armedAll then
			armedAll = true
			delAll.Text = "¿Seguro? toca otra vez"
			task.delay(3, function() armedAll = false if delAll.Parent then delAll.Text = "Borrar todas las notas" end end)
		else
			armedAll = false
			delAll.Text = "Borrar todas las notas"
			S.notes = {}
			editing = nil
			box.Text = ""
			save.Text = "Guardar"
			saveNow()
			renderNotes()
			addFeed("🧹 Todas las notas borradas", C.warn)
		end
	end)
	renderNotes()
end

-- ---------- AJUSTES ----------
do
	local p = pages.cfg
	local info = label(p, "", { Size = UDim2.new(1, 0, 0, 30), TextSize = 11, TextColor3 = C.txt })
	local function refresh()
		info.Text = "Clave en uso: " .. maskKey(S.apiKey) .. (S.apiKey == DEFAULT_KEY and " (original)" or " (personalizada)")
	end
	label(p, "Clave API de Groq", { Position = UDim2.fromOffset(0, 36), Size = UDim2.new(1, 0, 0, 16), TextSize = 11 })
	local keyBox = textbox(p, "Pega aquí tu nueva clave (gsk_...)", { Position = UDim2.fromOffset(0, 54), Size = UDim2.new(1, 0, 0, 34), TextSize = 12 })
	btn(p, "Guardar clave", { Position = UDim2.fromOffset(0, 94), Size = UDim2.new(0.5, -3, 0, 30), BackgroundColor3 = C.acc }, function()
		local k = trim(keyBox.Text)
		if k:sub(1, 4) ~= "gsk_" or #k < 20 then
			addFeed("⚠ Esa clave no parece válida (debe empezar por gsk_)", C.red)
			return
		end
		S.apiKey = k
		keyBox.Text = ""
		markDirty() refresh()
		addFeed("🔑 Clave actualizada", C.acc2)
	end)
	btn(p, "Volver a la original", { Position = UDim2.new(0.5, 3, 0, 94), Size = UDim2.new(0.5, -3, 0, 30), TextSize = 11 }, function()
		S.apiKey = DEFAULT_KEY
		keyBox.Text = ""
		markDirty() refresh()
		addFeed("🔑 Clave original restaurada", C.acc2)
	end)
	label(p, "Nivel de razonamiento de la IA", { Position = UDim2.fromOffset(0, 134), Size = UDim2.new(1, 0, 0, 16), TextSize = 11 })
	local eff
	local function paintEff()
		eff.Text = (S.effort == "low") and "BAJO · ahorra tokens (recomendado)" or "MEDIO · más listo, gasta más tokens"
		eff.TextColor3 = (S.effort == "low") and C.acc2 or C.warn
	end
	eff = btn(p, "", { Position = UDim2.fromOffset(0, 154), Size = UDim2.new(1, 0, 0, 32), TextSize = 11 }, function()
		S.effort = (S.effort == "low") and "medium" or "low"
		paintEff() markDirty()
	end)
	label(p, "Tamaño del panel (también puedes pellizcarlo con dos dedos)", { Position = UDim2.fromOffset(0, 196), Size = UDim2.new(1, 0, 0, 16), TextSize = 11 })
	btn(p, "－", { Position = UDim2.fromOffset(0, 216), Size = UDim2.new(0.25, -3, 0, 30), TextSize = 16 }, function() applyScale("main", (S.scales.main or 1) - 0.1) end)
	btn(p, "＋", { Position = UDim2.new(0.25, 3, 0, 216), Size = UDim2.new(0.25, -6, 0, 30), TextSize = 16 }, function() applyScale("main", (S.scales.main or 1) + 0.1) end)
	btn(p, "Restablecer tamaños", { Position = UDim2.new(0.5, 3, 0, 216), Size = UDim2.new(0.5, -3, 0, 30), TextSize = 11 }, function()
		applyScale("main", 1) applyScale("gate", 1) applyScale("reply", 1)
	end)
	label(p, "Con el filtro previo activo solo gastas tokens en los mensajes que apruebas.", { Position = UDim2.fromOffset(0, 256), Size = UDim2.new(1, 0, 0, 30), TextSize = 10 })
	refresh() paintEff()
end

showPage("home")

--// ============ PANELES DE NOTIFICACIONES ============
local function makePanel(title, icon, pos, width, color, key, cardH, onClearAll)
	local P = { items = {}, collapsed = false }
	local root = stroke(corner(frame(gui, { Size = UDim2.fromOffset(width, 34), Position = pos, BackgroundColor3 = C.bg, ClipsDescendants = true, Visible = false }), 12), color)
	registerScalable(root, key)
	local hdr = corner(frame(root, { Size = UDim2.new(1, 0, 0, 32), Active = true }), 12)
	frame(hdr, { Position = UDim2.new(0, 0, 1, -12), Size = UDim2.new(1, 0, 0, 12) })
	local ttl = label(hdr, "", { Font = Enum.Font.GothamBold, TextSize = 12, TextColor3 = C.txt, Position = UDim2.fromOffset(10, 0), Size = UDim2.new(1, -70, 1, 0), TextWrapped = false })
	makeDraggable(hdr, root)
	local list = scroller(root, { Position = UDim2.fromOffset(0, 34), Size = UDim2.new(1, 0, 1, -34) })
	local function resize()
		local n = #P.items
		root.Visible = n > 0
		ttl.Text = icon .. " " .. title .. " (" .. n .. ")"
		if P.collapsed then
			list.Visible = false
			root.Size = UDim2.fromOffset(width, 32)
		else
			list.Visible = true
			root.Size = UDim2.fromOffset(width, math.min(34 + n * (cardH + 4) + 8, 340))
		end
	end
	btn(hdr, "▾", { Size = UDim2.fromOffset(28, 22), Position = UDim2.new(1, -62, 0.5, -11), TextSize = 12 }, function()
		P.collapsed = not P.collapsed
		resize()
	end)
	btn(hdr, "🗑", { Size = UDim2.fromOffset(28, 22), Position = UDim2.new(1, -32, 0.5, -11), TextSize = 12, TextColor3 = C.red }, function()
		onClearAll(P)
	end)
	P.list = list
	P.add = function(card) table.insert(P.items, card) resize() end
	P.remove = function(card)
		for i, c in ipairs(P.items) do if c == card then table.remove(P.items, i) break end end
		card.frame:Destroy()
		resize()
	end
	return P
end

local function clearAll(P, msg)
	for i = #P.items, 1, -1 do P.remove(P.items[i]) end
	addFeed(msg, C.mute)
end

local gateP  = makePanel("¿Mandar a la IA?", "🛡", UDim2.fromOffset(16, 60), 240, C.warn, "gate", 118, function(P) clearAll(P, "🗑 Mensajes descartados (sin gastar tokens)") end)
local replyP = makePanel("Respuestas", "🔔", UDim2.new(1, -316, 0, 60), 300, C.acc, "reply", 150, function(P) clearAll(P, "🗑 Respuestas rechazadas") end)

-- Pellizco con dos dedos: escala el panel que tengas debajo
do
	local target, base
	local function inside(root, pos, margin)
		local p, s = root.AbsolutePosition, root.AbsoluteSize
		return pos.X >= p.X - margin and pos.X <= p.X + s.X + margin and pos.Y >= p.Y - margin and pos.Y <= p.Y + s.Y + margin
	end
	table.insert(conns, UIS.TouchPinch:Connect(function(positions, scale, velocity, state)
		if state == Enum.UserInputState.Begin then
			target = nil
			if #positions < 2 then return end
			local c = (positions[1] + positions[2]) / 2
			local inset = GuiService:GetGuiInset()
			for _, sc in ipairs(scalables) do
				if sc.root.Visible and (inside(sc.root, c, 40) or inside(sc.root, c + inset, 40)) then
					target, base = sc, sc.us.Scale
					break
				end
			end
		elseif state == Enum.UserInputState.Change then
			if target then
				target.us.Scale = math.clamp(base * scale, CONFIG.MIN_SCALE, CONFIG.MAX_SCALE)
				keepOnScreen(target.root)
			end
		else
			if target then
				S.scales[target.key] = target.us.Scale
				markDirty()
			end
			target = nil
		end
	end))
end

local order = 0
local function newCard(P)
	order = order + 1
	local f = stroke(corner(new("Frame", { BackgroundColor3 = C.panel, BorderSizePixel = 0, Size = UDim2.new(1, -6, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = order }, P.list), 10))
	new("UIListLayout", { Padding = UDim.new(0, 5), SortOrder = Enum.SortOrder.LayoutOrder }, f)
	new("UIPadding", { PaddingTop = UDim.new(0, 8), PaddingBottom = UDim.new(0, 8), PaddingLeft = UDim.new(0, 8), PaddingRight = UDim.new(0, 8) }, f)
	return f
end

local function ageText(ts)
	local s = now() - ts
	return s < 60 and (s .. " s") or (math.floor(s / 60) .. " min")
end

-- Filtro previo: aprobar = llamar a la IA; rechazar = no gasta nada y no se guarda
createGateCard = function(plr, text)
	local card = { name = plr.DisplayName, dist = math.floor(distTo(plr) or 0), ts = now() }
	local f = newCard(gateP)
	card.frame = f
	card.head = label(f, "", { Size = UDim2.new(1, 0, 0, 14), TextSize = 11, LayoutOrder = 1, TextWrapped = false })
	label(f, "💬 " .. text, { Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, TextColor3 = C.txt, LayoutOrder = 2 })
	label(f, "¿Mandar este mensaje a la IA?", { Size = UDim2.new(1, 0, 0, 14), TextSize = 10, LayoutOrder = 3 })
	local row = frame(f, { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 30), LayoutOrder = 4 })
	btn(row, "✔ Aprobar", { Size = UDim2.new(0.5, -3, 1, 0), BackgroundColor3 = C.acc2, TextColor3 = C.bg, TextSize = 11 }, function()
		gateP.remove(card)
		if S.enabled and plr.Parent == Players then enqueue({ kind = "chat", p = plr, t = text }) end
	end)
	btn(row, "✖ Rechazar", { Size = UDim2.new(0.5, -3, 1, 0), Position = UDim2.new(0.5, 3, 0, 0), TextColor3 = C.red, TextSize = 11 }, function()
		gateP.remove(card)
		addFeed("✖ Descartado sin gastar tokens (" .. card.name .. ")", C.mute)
	end)
	card.head.Text = "👤 " .. card.name .. " · " .. card.dist .. " studs · ahora"
	gateP.add(card)
end

-- Respuesta: enviar / modificar / rechazar (rechazar no guarda nada)
createCard = function(plr, text, proposal)
	local u = getUser(plr)
	local card = { out = proposal, ts = now(), busy = false, name = u.display, dist = math.floor(distTo(plr) or 0) }
	local f = newCard(replyP)
	card.frame = f

	card.head = label(f, "", { Size = UDim2.new(1, 0, 0, 14), TextSize = 11, LayoutOrder = 1, TextWrapped = false })
	label(f, "💬 " .. text, { Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, TextColor3 = C.txt, LayoutOrder = 2 })
	local pf = corner(frame(f, { BackgroundColor3 = C.panel2, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = 3 }), 8)
	new("UIPadding", { PaddingTop = UDim.new(0, 6), PaddingBottom = UDim.new(0, 6), PaddingLeft = UDim.new(0, 8), PaddingRight = UDim.new(0, 8) }, pf)
	local prop = label(pf, "🧥 " .. proposal, { Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, TextColor3 = PURPLE, Font = Enum.Font.GothamMedium })

	local row = frame(f, { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 30), LayoutOrder = 4 })
	local bSend = btn(row, "✔ Enviar", { Size = UDim2.new(1 / 3, -4, 1, 0), Position = UDim2.new(0, 2, 0, 0), BackgroundColor3 = C.acc2, TextColor3 = C.bg, TextSize = 11 })
	local bMod = btn(row, "✎ Modificar", { Size = UDim2.new(1 / 3, -4, 1, 0), Position = UDim2.new(1 / 3, 2, 0, 0), TextColor3 = C.warn, TextSize = 11 })
	local bRej = btn(row, "✖ Rechazar", { Size = UDim2.new(1 / 3, -4, 1, 0), Position = UDim2.new(2 / 3, 2, 0, 0), TextColor3 = C.red, TextSize = 11 })

	local ed = frame(f, { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 72), LayoutOrder = 5, Visible = false })
	local edBox = withMentions(textbox(ed, "¿Qué cambio quieres? (usa @ para etiquetar)", { Size = UDim2.new(1, 0, 0, 34), TextSize = 12 }))
	local bGen = btn(ed, "Generar nueva", { Position = UDim2.fromOffset(0, 40), Size = UDim2.new(0.6, -3, 0, 30), BackgroundColor3 = C.acc, TextSize = 11 })
	local bCan = btn(ed, "Cancelar", { Position = UDim2.new(0.6, 3, 0, 40), Size = UDim2.new(0.4, -3, 0, 30), TextSize = 11 })

	bSend.Activated:Connect(function()
		if card.busy then return end
		local out = card.out
		replyP.remove(card)
		commitReply(plr, text, out)
	end)
	bRej.Activated:Connect(function()
		if card.busy then return end
		replyP.remove(card)
		addFeed("✖ Respuesta rechazada (" .. card.name .. "): no se guardó nada en la memoria", C.mute)
	end)
	bMod.Activated:Connect(function()
		if card.busy then return end
		ed.Visible = not ed.Visible
	end)
	bCan.Activated:Connect(function() ed.Visible = false end)
	bGen.Activated:Connect(function()
		local ins = trim(edBox.Text)
		if ins == "" or card.busy then return end
		card.busy = true
		ed.Visible = false
		prop.Text = "⏳ Generando nueva respuesta..."
		task.spawn(function()
			local out, err = regenerate(plr, text, card.out, expandMentions(ins))
			card.busy = false
			if not f.Parent then return end
			if out then
				card.out = out
				edBox.Text = ""
			else
				addFeed("⚠ " .. tostring(err), C.red)
			end
			prop.Text = "🧥 " .. card.out
		end)
	end)

	replyP.add(card)
end

--// ============ BUCLES ============
task.spawn(function()
	while alive do
		local near = nearby()
		local names = {}
		for _, e in ipairs(near) do table.insert(names, e.p.DisplayName) end
		nearLabel.Text = "Radio " .. CONFIG.RADIUS .. " studs · Cerca (" .. #near .. "): " .. (#names > 0 and table.concat(names, ", ") or "nadie")
			.. "\nTokens usados en esta sesión: " .. usedTokens
		for _, P in ipairs({ gateP, replyP }) do
			for _, c in ipairs(P.items) do
				c.head.Text = "👤 " .. c.name .. " · " .. c.dist .. " studs · hace " .. ageText(c.ts)
			end
		end
		task.wait(1)
	end
end)
task.spawn(function()
	while alive do
		task.wait(15)
		if dirty then saveNow() end
	end
end)

addFeed("✅ Listo. Solo responde a quien esté a " .. CONFIG.RADIUS .. " studs o menos.", C.acc2)
if #S.notes > 0 then addFeed("📌 " .. #S.notes .. " nota(s) permanente(s) cargada(s).", C.acc2) end
if wipedAtStart then addFeed("🧹 Memoria anterior borrada: empiezas desde cero.", C.warn) end
if not httpRequest then addFeed("⚠ Tu ejecutor no tiene función request/http_request.", C.red) end
if not canFS then addFeed("⚠ Sin writefile/readfile: la memoria y las notas no se guardarán al cerrar.", C.warn) end
