-- HOW TO PLAY: the rules of Kubb on six cards, for someone who has never
-- played, in the words a friend would use on the lawn (Rules V4.0 as the game
-- plays them: core/rules). The cards come before HOW TO THROW (core/howto):
-- the last one leads into it. Pure: the text, what each card's little pitch
-- shows, and the paging; render/howtoplay draws a card, scenes/howtoplay
-- runs them.
--
--   howtoplay.CARDS          the cards: { id, title, text = { paragraphs },
--                            map = { pieces, arrow, line } or nil }
--   howtoplay.new()          { page = 1 }
--   howtoplay.press(st, b)   b = "a" | "b" | "left" | "right": turns the page;
--                            returns "howto" (A on the last card: on to HOW TO
--                            THROW), "exit" (B on the first or the last card)
--                            or nil
--
-- Map coordinates are world metres as everywhere (x across, y from your
-- baseline at 0 to theirs at 8). Pieces: base (a kubb standing on a
-- baseline), field (a field kubb standing), down (a kubb knocked over), king.
import "core/tw"

local howtoplay = {}

local BASES = {}
for i, x in ipairs({ -2, -1, 0, 1, 2 }) do
	BASES[i] = { kind = "base", x = x, y = 0 }
	BASES[5 + i] = { kind = "base", x = x, y = 8 }
end

local function with(list, extra)
	local out = {}
	for _, p in ipairs(list) do out[#out + 1] = p end
	for _, p in ipairs(extra) do out[#out + 1] = p end
	return out
end

local KING = { kind = "king", x = 0, y = 4 }

-- Their base kubbs all down, ours standing: the king's card.
local KINGPITCH = {}
for i, x in ipairs({ -2, -1, 0, 1, 2 }) do
	KINGPITCH[i] = { kind = "base", x = x, y = 0 }
	KINGPITCH[5 + i] = { kind = "down", x = x, y = 8 }
end
KINGPITCH[11] = KING

howtoplay.CARDS = {
	{ id = "pitch", title = "THE PITCH",
		text = { "TWO TEAMS, ONE AT EACH END OF A PATCH OF LAWN 8 M LONG AND 5 M WIDE.",
			"EACH TEAM HAS FIVE KUBBS STANDING ON ITS BASELINE. THE KING STANDS IN THE MIDDLE.",
			"KNOCK DOWN ALL OF THEIR KUBBS, THEN THE KING, AND YOU WIN." },
		map = { pieces = with(BASES, { KING }) } },
	{ id = "batons", title = "BATONS",
		text = { "ON YOUR TURN YOU GET SIX BATONS TO THROW AT THEIR KUBBS.",
			"THROW THEM UNDERARM SO THEY TURN END OVER END. ONE THAT SPINS FLAT LIKE A HELICOPTER DOESN'T COUNT.",
			"IN THE 2-4-6 OPENING THE FIRST TURN GETS TWO AND THE SECOND FOUR." },
		map = { pieces = with(BASES, { KING }), arrow = { 0.3, 0.4, 1, 7.6 } } },
	{ id = "back", title = "THROW THEM BACK IN",
		text = { "EVERY KUBB YOU KNOCK DOWN, THEY THROW BACK INTO YOUR HALF.",
			"YOU STAND THEM UP WHERE THEY LAND. NOW THEY'RE FIELD KUBBS.",
			"IF ONE LANDS OUT THEY THROW IT AGAIN. OUT TWICE, YOU PICK THE SPOT." },
		map = { pieces = with(BASES, { KING, { kind = "field", x = -1.2, y = 2.6 }, { kind = "field", x = 0.9, y = 3.2 },
			{ kind = "field", x = 1.5, y = 1.9 } }), arrow = { 0.6, 7.6, 0.9, 3.5 } } },
	{ id = "field", title = "FIELD KUBBS FIRST",
		text = { "THEIR FIELD KUBBS COME FIRST, THEN THE ONES ON THEIR BASELINE.",
			"HIT A BASE KUBB TOO SOON AND IT JUST GETS STOOD BACK UP.",
			"LEAVE ANY STANDING AND NEXT TURN THEY STEP UP AND THROW FROM THE ONE NEAREST THE MIDDLE." },
		map = { pieces = with(BASES, { KING, { kind = "field", x = -0.9, y = 5.3 }, { kind = "field", x = 1.1, y = 6.2 } }),
			line = 5.3 } },
	{ id = "king", title = "THE KING LAST",
		text = { "ONCE ALL THEIR KUBBS ARE DOWN, GO FOR THE KING FROM YOUR BASELINE. KNOCK HIM OVER AND YOU WIN.",
			"KNOCK THE KING OVER TOO EARLY AND YOU LOSE. SAME IF A KUBB YOU THROW IN KNOCKS HIM OVER." },
		map = { pieces = KINGPITCH, arrow = { 0, 0.4, 0, 3.6 } } },
	{ id = "sheet", title = "THE SCORE SHEET",
		text = { "EVERY GAME GETS WRITTEN DOWN BATON BY BATON IN PLANET KUBB NOTATION, THE SAME WAY TOURNAMENT SCOREKEEPERS DO IT.",
			"TO LOOK BACK AT YOUR GAMES, OPEN THE SYSTEM MENU ON THE TITLE AND PICK GAMES.",
			"THAT'S KUBB. NEXT UP: HOW TO THROW WITH THE CRANK." } },
}

function howtoplay.new()
	return { page = 1 }
end

function howtoplay.press(st, b)
	local n = #howtoplay.CARDS
	if b == "a" then
		if st.page == n then return "howto" end
		st.page = st.page + 1
	elseif b == "right" then
		if st.page < n then st.page = st.page + 1 end
	elseif b == "left" then
		if st.page > 1 then st.page = st.page - 1 end
	elseif b == "b" then
		if st.page == 1 or st.page == n then return "exit" end
		st.page = st.page - 1
	end
	return nil
end

tw.howtoplay = howtoplay
