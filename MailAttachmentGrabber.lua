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
	
	-- Hook Mail.ToggleWindow so overlay can be loaded / button updated
	self.mailToggleWindow = Mail.ToggleWindow 
	Mail.ToggleWindow = self.MailToggleWindowIntercept
	
	-- Hook Mail.UpdateAllListItems so button text can be updated on mail select/deselect
	self.mailUpdateAllListItems = Mail.UpdateAllListItems
	Mail.UpdateAllListItems = self.MailUpdateAllListItemsIntercept
end

-- Intercept Mail-addons "OnDocumentReady" so that my own overlay can be added to the window
function MailAttachmentGrabber:MailToggleWindowIntercept()
	local Mail = Apollo.GetAddon("Mail")

	-- If Mail is not yet fully initialized, or being closed, do nothing
	if Mail.wndMain == nil or Mail.wndMain:FindChild("MailForm") == nil or Mail.wndMain:IsVisible() then 
		MailAttachmentGrabber.mailToggleWindow(Mail)
		return 
	end
	
	-- Load overlay form, if not already done
	if MailAttachmentGrabber.wndOverlay == nil then
		local wndOverlayParent = Mail.wndMain:FindChild("MailForm")
		MailAttachmentGrabber.wndOverlay = Apollo.LoadForm(MailAttachmentGrabber.xmlDoc, "ButtonOverlay", wndOverlayParent, MailAttachmentGrabber)
	end
		
	-- Set correct button text
	MailAttachmentGrabber:UpdateButton()
	
	-- Allow Mail.ToggleWindow to complete as usual
	MailAttachmentGrabber.mailToggleWindow(Mail)
end

-- Intercept Mail-addons "UpdateAllListItems" (which is called whenever anything has changed/needs updating)
-- so that the grab-button can be updated accordingly.
function MailAttachmentGrabber:MailUpdateAllListItemsIntercept()
	local Mail = Apollo.GetAddon("Mail")
	
	-- Allow Mail.OnUpdateAllListItemsIntercept to complete as usual
	MailAttachmentGrabber.mailUpdateAllListItems(Mail)

	-- Update and store list of selected mail IDs and attachment-summary for these mails
	MailAttachmentGrabber.tMailIdList = MailAttachmentGrabber:GetSelectedMailIds()
	MailAttachmentGrabber.tAttachmentsList = MailAttachmentGrabber:GetAttachments()
	
	-- Update the overlay button text
	MailAttachmentGrabber:UpdateButton()
	MailAttachmentGrabber:UpdateTooltip()
end

-- Called whenever the button text should be recalculated
function MailAttachmentGrabber:UpdateButton()
	-- Intercepted function UpdateButton may be called at times when my overlay is not present yet
	if self.wndOverlay == nil then return end	
	
	-- Locate overlay button
	local btn = self.wndOverlay:FindChild("GrabAttachmentsButton")
	
	-- Default text is "Take All"
	local text = L["TakeAll"]
	
	-- If any mails are selected (even if all are selected), update text from "All" to "Selected"
	if self.tMailIdList ~= nil and #self.tMailIdList > 0 then
		text = L["TakeSelected"]
	end
	
	-- Set button text	
	btn:SetText(text)

	-- Enable or disable, depending on attachments to grab
	btn:Enable(self.tAttachmentsList ~= nil and #self.tAttachmentsList > 0)
end

-- Scans the Mail GUI for selected mail indices. Returns list containing selected mail id-strings.
-- Empty list returned = no mails are selected
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
function MailAttachmentGrabber:GetAttachments()	
	
	-- Reverse list of selected ids into map of selectedId->true
	local tIsIdSelected = {}	
	for k,v in ipairs(self.tMailIdList) do tIsIdSelected[v] = true end
	
	-- Scan all selected (or just all, if none are selected) mails, and build cummulitative list of attachments
	local tAttachments = {}

	local Mail = Apollo.GetAddon("Mail")	
	for _,mail in pairs(MailSystemLib.GetInbox()) do
		if #self.tMailIdList == 0 or tIsIdSelected[mail:GetIdStr()] == true then
			-- Mail is selected (or none are selected). Include in summary if it has attachments and is not COD.			
			local tMsgAttachments = mail:GetMessageInfo().arAttachments
			local bHasAttachments = (tMsgAttachments ~= nil and #tMsgAttachments)
			local bIsCOD = not mail:GetMessageInfo().monCod:IsZero()			
			local bIsGift = not mail:GetMessageInfo().monGift:IsZero()			
			
			if (not bIsCOD) and (bIsGift or bHasAttachments) then			
				-- Add attachments summary 
				for _,msgAttachment in pairs(tMsgAttachments) do
					if tAttachments[msgAttachment.itemAttached:GetItemId()] ~= nil then
						-- Attachment type already seen, just add stackcount						
						tAttachments[msgAttachment.itemAttached:GetItemId()].nStackCount = tAttachments[msgAttachment.itemAttached:GetItemId()].nStackCount + msgAttachment.nStackCount
					else
						local newAttachmentType = {}
						newAttachmentType.itemAttached = msgAttachment.itemAttached
						newAttachmentType.nStackCount = msgAttachment.nStackCount						
						tAttachments[msgAttachment.itemAttached:GetItemId()] = newAttachmentType
					end
				end
				
				-- Add cash summary
				if bIsGift then
					if type(tAttachments["Cash"]) ~= "number" then 
						tAttachments["Cash"] = 0 
					end
					tAttachments["Cash"] = tAttachments["Cash"] + mail:GetMessageInfo().monGift:GetAmount()
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
	if self.bGrabInProgress == true then return end

	-- Reverse list of selected ids into map of selectedId->true
	self.bGrabInProgress = true
		
	local tIsIdSelected = {}	
	for k,v in ipairs(self.tMailIdList) do tIsIdSelected[v] = true end
	
	local Mail = Apollo.GetAddon("Mail")	
	for _,mail in pairs(MailSystemLib.GetInbox()) do
		if #self.tMailIdList == 0 or tIsIdSelected[mail:GetIdStr()] == true then
			-- Mail is selected (or none are selected). Include in summary if it has attachments and is not COD.			
			local tMsgAttachments = mail:GetMessageInfo().arAttachments
			local bHasAttachments = (tMsgAttachments ~= nil and #tMsgAttachments)
			local bIsCOD = not mail:GetMessageInfo().monCod:IsZero()			
			local bIsGift = not mail:GetMessageInfo().monGift:IsZero()			
			
			-- Safeguard against COD even though such mails should never be on this list to begin with
			if not bIsCOD then 
				if bIsGift then
					mail:TakeMoney()
				end
				
				if bHasAttachments then
					mail:TakeAllAttachments()
				end
			end
				
			-- Mark as read and select mail so it can be manually deleted later on
			mail:MarkAsRead()			
			Mail.tMailItemWnds[mail:GetIdStr()]:FindChild("SelectMarker"):SetCheck(true)
		end
	end
	
	self.bGrabInProgress = false
end

-- First-time generation of tooltip window
function MailAttachmentGrabber:OnGenerateTooltip(wndHandler, wndControl, eToolTipType, x, y)	
	self.wndTooltip = wndControl:LoadTooltipForm("MailAttachmentGrabber.xml", "TooltipForm")
end

function MailAttachmentGrabber:UpdateTooltip()
	if self.wndTooltip == nil then return end
	
	-- Used to determine width of tooltip window
	local maxLineWidth = 0
	
	-- Add individual item-lines to tooltip
	self.wndTooltip:DestroyChildren()
	for _,attachment in pairs(self.tAttachmentsList) do
		if type(attachment) == "number" then
			local wndLine = Apollo.LoadForm(self.xmlDoc, "TooltipCashLineForm", self.wndTooltip, MailAttachmentGrabber)
			wndLine:FindChild("CashWindow"):SetAmount(attachment, true)
			if maxLineWidth < 100 then maxLineWidht = 150 end
		else
			local wndLine = Apollo.LoadForm(self.xmlDoc, "TooltipItemLineForm", self.wndTooltip, MailAttachmentGrabber)
			wndLine:FindChild("ItemIcon"):SetSprite(attachment.itemAttached:GetIcon())
			
			local str = attachment.itemAttached:GetName() .. " (x" .. attachment.nStackCount .. ")"
			wndLine:FindChild("ItemName"):SetText(str)
			
			-- Update max line width if this text is the longest added so far
			local nCurrLineWidth = Apollo.GetTextWidth("CRB_InterfaceSmall", str)		
			if nCurrLineWidth > maxLineWidth then maxLineWidth = nCurrLineWidth end
		end
	end
	
	-- Sort lines according to name
	self.wndTooltip:ArrangeChildrenVert(0, 
		function(a, b)
			if a:GetName() == "TooltipCashLineForm" then return true end
			if b:GetName() == "TooltipCashLineForm" then return false end
			return a:FindChild("ItemName"):GetText() < b:FindChild("ItemName"):GetText()
		end)
	
	-- Resize window width and height. Gief moar magic numbers plox!
	self.wndTooltip:SetAnchorOffsets(0, 0, maxLineWidth+80, 18+#self.tAttachmentsList*24)
end

MailAttachmentGrabber = MailAttachmentGrabber:new()
MailAttachmentGrabber:Init()
