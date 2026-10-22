--!strict
-- Universe at Home: Meadow :: Bake (server)
--
-- AssetService:CreateDataModelContentAsync turns an EditableImage or EditableMesh into
-- DataModel-scoped Opaque content that replicates to clients, gets real mips, and does
-- not count against client editable budgets (docs/RUNTIME_AUDIT.md section 3). It
-- returns (Enum.CreateContentResult, Content). Every caller has a fallback, because
-- an unbaked server EditableImage must never be assigned to a replicating instance
-- (clients would see the placeholder checkerboard).

local AssetService = game:GetService("AssetService")

local Bake = {}

Bake.attempts = 0
Bake.successes = 0
Bake.lastError = nil :: string?

-- Returns (content, nil) on success or (nil, reason).
function Bake.object(object: EditableImage | EditableMesh): (Content?, string?)
	Bake.attempts += 1
	local ok, result, content = pcall(function(): (any, any)
		return AssetService:CreateDataModelContentAsync(Content.fromObject(object))
	end)
	if not ok then
		Bake.lastError = tostring(result)
		return nil, "CreateDataModelContentAsync threw: " .. tostring(result)
	end
	if result ~= Enum.CreateContentResult.Success then
		Bake.lastError = tostring(result)
		return nil, "CreateDataModelContentAsync returned " .. tostring(result)
	end
	if typeof(content) ~= "Content" then
		Bake.lastError = "no Content returned"
		return nil, "no Content returned"
	end
	Bake.successes += 1
	return content :: Content, nil
end

-- Writes an RGBA8 buffer into a new EditableImage and bakes it. The source image is
-- kept alive (returned) because whether it may be destroyed right after baking is
-- NOT PUBLICLY SPECIFIED.
function Bake.pixels(width: number, height: number, pixels: buffer): (Content?, EditableImage?, string?)
	local img = AssetService:CreateEditableImage({ Size = Vector2.new(width, height) })
	if not img then
		return nil, nil, "CreateEditableImage returned nil"
	end
	img:WritePixelsBuffer(Vector2.zero, Vector2.new(width, height), pixels)
	local content, why = Bake.object(img)
	return content, img, why
end

return Bake
