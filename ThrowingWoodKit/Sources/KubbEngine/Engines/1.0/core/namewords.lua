-- The words generated names are made of (core/namegen, docs/NAMES.md). Pure data:
-- no playdate.*.
--
-- Every name a player can have is one of these words joined to another, so the
-- lists ARE the safety policy: there is no free text to filter. A word goes in only
-- if it is friendly at any age, says nothing about a body, a people, a faith or a
-- health condition, and joins safely with every word it can meet. That last test is
-- `make names`: it writes every name the lists can make to tests/names/, and the
-- diff of a pull request shows each new name a new word makes.
--
-- Rules for changing a list (docs/NAMES.md "Changing the words"):
--   * Add at the end or anywhere; order does not matter (names are text, never an index).
--   * Removing a word makes names that hold it invalid. Remove only for safety, and
--     say so in the pull request.
--   * One word per entry, letters only, capitalised. Lengths are checked by the tests.
--
-- Lineage: `adjectives` begins with the 2012 Planet Kubb Name Generator's own list,
-- and the "-kubb" nouns in `teams` are the best of its dictionary blends.
import "core/tw"

local words = {}

-- Bump when a list changes, so a client can tell a host it holds other words.
words.version = 1

-- Before a wood (players) or a team noun (teams).
words.adjectives = {
	-- From the Planet Kubb Name Generator (2012).
	"Agreeable", "Brave", "Calm", "Delightful", "Eager", "Faithful", "Gentle", "Happy",
	"Jolly", "Kind", "Lively", "Proud", "Silly", "Thankful", "Victorious", "Witty",
	"Zealous", "Mighty", "Magnificent",
	-- Throwing Wood.
	"Bold", "Breezy", "Bright", "Brisk", "Busy",
	"Careful", "Cheery", "Clever", "Cosy", "Crafty", "Curious",
	"Dapper", "Daring", "Dashing", "Dizzy", "Dreamy",
	"Early", "Epic",
	"Fancy", "Fearless", "Feisty", "Fizzy", "Frosty", "Fuzzy",
	"Gallant", "Giddy", "Glorious", "Golden", "Grand", "Grumpy",
	"Handy", "Hasty", "Hearty", "Heroic", "Honest", "Humble",
	"Jaunty", "Jazzy", "Jumpy",
	"Keen",
	"Lucky", "Loyal",
	"Mellow", "Merry", "Mossy", "Muddy",
	"Nifty", "Nimble", "Noble",
	"Patient", "Peppy", "Plucky", "Polite",
	"Quick", "Quiet", "Quirky",
	"Rapid", "Rowdy", "Royal", "Rustic", "Rusty",
	"Salty", "Shiny", "Sleepy", "Sly", "Snappy", "Speedy", "Spry", "Steady",
	"Stormy", "Sunny", "Swift",
	"Tidy", "Trusty", "Tumbling",
	"Upbeat",
	"Valiant",
	"Wandering", "Wily", "Windy", "Wobbly", "Wonky",
	"Zany", "Zesty", "Zippy",
	-- After real teams' names and the kubb press (docs/NAMES.md "Where the words come from").
	"Backyard", "Cheerful", "Midsummer", "Northern", "Sneaky", "Thundering",
}

-- A player is an adjective and a wood: "Mighty Maple". Trees and timbers only.
words.woods = {
	"Alder", "Ash", "Aspen", "Balsa", "Baobab", "Birch",
	"Cedar", "Chestnut", "Cypress", "Elder", "Elm", "Fir",
	"Ginkgo", "Hazel", "Hickory", "Holly", "Juniper", "Kapok", "Larch",
	"Laurel", "Linden", "Mahogany", "Maple", "Myrtle", "Oak", "Olive",
	"Pear", "Pine", "Plum", "Poplar", "Redwood", "Sequoia",
	"Spruce", "Sumac", "Sycamore", "Tamarack", "Teak", "Walnut", "Willow",
}

-- A team is "<adjective> <noun>", "The <noun>" or "<wood> <noun>": "Wobbly Towers",
-- "The Lumberjacks", "Birch Batons". Plural nouns from the game and the backyard.
words.teams = {
	-- The game.
	"Batons", "Kings", "Kubbs", "Drillers", "Blasters", "Helicopters", "Corners",
	"Baseliners", "Fielders", "Eights", "Stakes", "Towers", "Fences", "Toppers",
	"Wobblers", "Rollers",
	-- Blends, after the 2012 generator's dictionary of "-kubb" words.
	"Kubbsters", "Kubblets", "Kubbinators", "Driftkubbs", "Ironkubbs", "Pinekubbs",
	"Firekubbs", "Wildkubbs", "Cedarkubbs", "Teakkubbs", "Torchkubbs", "Kingkubbs",
	"Kubbernauts", "Kubbcakes", "Kubbteers",
	-- Wood and the woods.
	"Lumberjacks", "Woodchucks", "Woodcutters", "Whittlers", "Carvers",
	"Splinters", "Stumps", "Timbers", "Acorns", "Pinecones", "Saplings", "Branches",
	"Twigs", "Logrollers", "Owls", "Moose", "Badgers", "Foxes", "Otters",
	-- The north kubb comes from.
	"Trolls", "Longboats", "Cloudberries", "Kanelbullar",
	-- The backyard.
	 "Lawnmowers", "Sprinklers", "Hammocks", "Campers",
}

-- Whole names that are never made, though each word is fine: a pair that reads badly,
-- sounds like something else, or is someone's name. core/namegen refuses them, so a
-- good word need not go for one bad partner. Each says why (docs/NAMES.md "Safety").
words.never = {
	"Salty Walnut", "Salty Chestnut", "Fuzzy Walnut", "Fuzzy Chestnut", "Fuzzy Plum", -- nut jokes
	"Holly Rollers",                     -- "holy rollers", a jibe at a faith
	"Mossy Oak", "Royal Oak", "Happy Pear", -- brands
	"Daring Ash", "Dashing Ash", "Thundering Ash", "Tumbling Ash", "Wandering Ash", -- run together: "gash"
	"Midsummer Kings", "Midsummer Kingkubbs", -- run together: "merkin"
}

tw.namewords = words
