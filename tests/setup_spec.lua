local diff = require("mini.diff")

describe("mini.diff", function()
  it("setup creates global object", function()
    diff.setup()
    assert.are.same("table", type(_G.MiniDiff))
  end)
end)
