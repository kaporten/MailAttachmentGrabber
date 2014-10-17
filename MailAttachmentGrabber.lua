--[[
	MailAttachmentGrabber by porten. Comments/suggestions etc are welcome, just look me up on Curse.
]]

require "Window"

local MailAttachmentGrabber = {}
local L = Apollo.GetPackage("Gemini:Locale-1.0").tPackage:GetLocale("MailAttachmentGrabber")
 
function MailAttachmentGrabber:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self 
    return o
end

function MailAttachmentGrabber:Init()
	local bHasConfigureFunction = false
	local strConfigureButtonText = ""
	local tDependencies = {
		 "Mail",
	}
    Apollo.RegisterAddon(self, bHasConfigureFunction, strConfigureButtonText, tDependencies)
end
 
function MailAttachmentGrabber:OnLoad()
    -- Load form for later use
	self.xmlDoc = XmlDoc.CreateFromFile("MailAttachmentGrabber.xml")
	self.xmlDoc:RegisterCallback("OnDocLoaded", self)
end

function MailAttachmentGrabber:OnDocLoaded()
	local Mail = Apollo.GetAddon("Mail")
	
	-- Hook Mail.OnDocumentReady so overlay can be loaded
	self.mailOnDocumentReady = Mail.OnDocumentReady
	Mail.OnDocumentReady = self.MailOnDocumentReadyIntercept
	
	-- Hook Mail.UpdateAllListItems so button text can be updated on mail select/deselect
	self.mailUpdateAllListItems = Mail.UpdateAllListItems
	Mail.UpdateAllListItems = self.MailUpdateAllListItemsIntercept
end

-- Intercept Mail-addons "OnDocumentReady" so that my own overlay can be added to the window
function MailAttachmentGrabber:MailOnDocumentReadyIntercept()
	local Mail = Apollo.GetAddon("Mail")
	
	-- Allow Mail.OnDocumentReady to complete as usual
	MailAttachmentGrabber.mailOnDocumentReady(Mail)
	
	-- Then load overlay form
	local wndOverlayParent = Mail.wndMain:FindChild("MailForm")
	MailAttachmentGrabber.wndOverlay = Apollo.LoadForm(MailAttachmentGrabber.xmlDoc, "ButtonOverlay", wndOverlayParent, MailAttachmentGrabber)
	
	-- Set correct button text
	MailAttachmentGrabber:UpdateButton()
end

-- Intercept Mail-addons "UpdateAllListItems" (which is called whenever anything has changed/needs updating)
-- so that the grab-button can be updated accordingly.
function MailAttachmentGrabber:MailUpdateAllListItemsIntercept()
	local Mail = Apollo.GetAddon("Mail")
	
	-- Allow Mail.OnUpdateAllListItemsIntercept to complete as usual
	MailAttachmentGrabber.mailUpdateAllListItems(Mail)

	-- Then update our overlay button text
	MailAttachmentGrabber:UpdateButton()
end

-- Called whenever the button text should be recalculated
function MailAttachmentGrabber:UpdateButton()
	-- Intercepted function UpdateButton may be called at times when my overlay is not present yet
	if self.wndOverlay == nil then return end

	-- Locate overlay button
	local btn = self.wndOverlay:FindChild("GrabAttachmentsButton")
	
	-- Default text is "Take All"
	local text = L["TakeAll"]
	local Mail = Apollo.GetAddon("Mail")

	-- If any mails are selected (even if all are selected), update text from "All" to "Selected"
	local selectedIds = MailAttachmentGrabber:GetSelectedMailIds()
	if #selectedIds > 0 then
		text = L["TakeSelected"]
	end
	
	--local hasAttachments = MailAttachmentGrabber:HasAttachments(selectedIds)
	local tAttachments = MailAttachmentGrabber:GetAttachments(selectedIds)
	MailAttachmentGrabber.tAttachments = tAttachments
	btn:Enable(tAttachments ~= nil and #tAttachments > 0)
	
	btn:SetText(text)
end

-- Scans the Mail GUI for selected mail indices. Returns list containing selected mail id-strings.
function MailAttachmentGrabber:GetSelectedMailIds()	
	local Mail = Apollo.GetAddon("Mail")
	local selectedIds = {}
	
	for idStr, wndMail in pairs(Mail.tMailItemWnds) do
		if wndMail:FindChild("SelectMarker"):IsChecked() then
			selectedIds[#selectedIds+1] = idStr
		end		
	end
	return selectedIds
end

-- Returns true if any of the selected mail-indices has attachments. 
-- If selectedIds input is empty, returns true if ANY mail has attachments.
function MailAttachmentGrabber:GetAttachments(selectedIds)	
	selectedIds = selectedIds or {}
	
	-- Reverse list of selected indexes into map of selectedId->true
	local tIsSelected = {}	
	for k,v in ipairs(selectedIds) do tIsSelected[v] = true end
	
	
	local tAttachments = {}
	local Mail = Apollo.GetAddon("Mail")	
	for _,mail in pairs(MailSystemLib.GetInbox()) do
		if #selectedIds == 0 or tIsSelected[mail:GetIdStr()] == true then
			local tMsgAttachments = mail:GetMessageInfo().arAttachments
			if tMsgAttachments ~= nil and #tMsgAttachments > 0 then
				for _,msgAttachment in pairs(tMsgAttachments) do
					if tAttachments[msgAttachment.itemAttached:GetItemId()] ~= nil then
						-- Attachment type already seen, just add stackcount
						--Print("New attachment")
						tAttachments[msgAttachment.itemAttached:GetItemId()].nStackCount = tAttachments[msgAttachment.itemAttached:GetItemId()].nStackCount + msgAttachment.nStackCount
					else
						--Print("More of existing attachment")	
						-- Attachment type not seen before, add to tAttachment array
						local newAttachmentType = {}
						newAttachmentType.itemAttached = msgAttachment.itemAttached
						newAttachmentType.nStackCount = msgAttachment.nStackCount						
						tAttachments[msgAttachment.itemAttached:GetItemId()] = newAttachmentType
					end
				end
			end
		end
	end
	
	-- Convert [id]->[attachment] map to pure list of [idx]->[attachment]
	local result = {}
	for k,v in pairs(tAttachments) do
		result[#result+1] = v
	end
	
	return result
end

function MailAttachmentGrabber:OnGrabAttachmentsBtn()
	Print(self.wndOverlay:FindChild("GrabAttachmentsButton"):GetText())
	
	
end

MailAttachmentGrabber = MailAttachmentGrabber:new()
MailAttachmentGrabber:Init()

---------------------------------------------------------------------------------------------------
-- ButtonOverlay Functions
---------------------------------------------------------------------------------------------------
function MailAttachmentGrabber:OnGenerateTooltip(wndHandler, wndControl, eToolTipType, x, y)
	local wndTooltip = wndControl:LoadTooltipForm("MailAttachmentGrabber.xml", "TooltipForm")
	
	-- Add individual item-lines to tooltip
	local maxLineWidth = 0
	for _,attachment in ipairs(self.tAttachments) do
		local wndLine = Apollo.LoadForm(self.xmlDoc, "TooltipLineForm", wndTooltip, MailAttachmentGrabber)
		wndLine:FindChild("ItemIcon"):SetSprite(attachment.itemAttached:GetIcon())
		
		local str = attachment.itemAttached:GetName() .. " (x" .. attachment.nStackCount .. ")"
		wndLine:FindChild("ItemName"):SetText(str)
		
		-- Update max line width if this text is the longest added so far
		local nCurrLineWidth = Apollo.GetTextWidth("CRB_InterfaceSmall", str)		
		if nCurrLineWidth > maxLineWidth then maxLineWidth = nCurrLineWidth end
	end
	
	-- Sort according to name
	wndTooltip:ArrangeChildrenVert(0, 
		function(a, b) 
			return a:FindChild("ItemName"):GetText() < b:FindChild("ItemName"):GetText()
		end)
	
	-- Resize window width and height. Gief moar magic numbers plox!
	wndTooltip:SetAnchorOffsets(0, 0, maxLineWidth+80, 18+#self.tAttachments*24)
end

