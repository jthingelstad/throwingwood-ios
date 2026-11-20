-- The one global namespace. Every core module adds itself as a field of `tw`
-- (tw.vec, tw.quat, ...). Pure Lua: no playdate.* anywhere under core/.
tw = tw or {}
