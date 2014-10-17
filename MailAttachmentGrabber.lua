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

	-- If any mails are selected (even if all are selected)
	local selectedIdx = MailAttachmentGrabber:GetSelectedMailIndices()
	if #selectedIdx > 0 then
		text = L["TakeSelected"]
	end
	
	local hasAttachments = MailAttachmentGrabber:HasAttachments(selectedIdx)
	btn:Enable(hasAttachments)
	
	btn:SetText(text)
end

-- Scans the Mail GUI for selected mail indices. Returns list containing selected indexes.
function MailAttachmentGrabber:GetSelectedMailIndices()	
	local Mail = Apollo.GetAddon("Mail")
	local selectedIdx = {}
	
	for idStr, wndMail in pairs(Mail.tMailItemWnds) do
		if wndMail:FindChild("SelectMarker"):IsChecked() then
			selectedIdx[#selectedIdx+1] = idStr
		end		
	end
	return selectedIdx
end

-- Returns true if any of the selected mail-indices has attachments. 
-- If selectedIdx input is empty, returns true if ANY mail has attachments.
function MailAttachmentGrabber:HasAttachments(selectedIdx)	
	selectedIdx = selectedIdx or {}
	
	-- Reverse list of selected indexes into map of selectedIndex->true
	local tIsSelected = {}	
	for k,v in ipairs(selectedIdx) do tIsSelected[v] = true end
	
	local Mail = Apollo.GetAddon("Mail")	
	for _,mail in pairs(MailSystemLib.GetInbox()) do
		if #selectedIdx == 0 or tIsSelected[mail:GetIdStr()] == true then
			local attachments = mail:GetMessageInfo().arAttachments
			if attachments ~= nil and #attachments > 0 then 				
				return true
			end
		end
	end
	
	return false
end

function MailAttachmentGrabber:OnGrabAttachmentsBtn()
	Print(self.wndOverlay:FindChild("GrabAttachmentsButton"):GetText())
	
	
end

MailAttachmentGrabber = MailAttachmentGrabber:new()
MailAttachmentGrabber:Init()
