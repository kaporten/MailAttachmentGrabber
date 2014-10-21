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
	local bHasConfigureFunction = true
	local strConfigureButtonText = "Mail Att. Grab."
	local tDependencies = {
		 "Mail",
	}
    Apollo.RegisterAddon(self, bHasConfigureFunction, strConfigureButtonText, tDependencies)
	
	-- Prepare default configuration, if none was loaded
	if self.tConfig == nil then
		self.tConfig = {}
		self.tConfig.nTimer = 0 -- ms delay per default
	end
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
	
	-- Load settings form and populate values
	self.wndSettings = Apollo.LoadForm(self.xmlDoc, "SettingsForm", nil, self)
	self.wndSettings:Show(false, true)
	self.wndSettings:FindChild("Slider"):SetValue(self.tConfig.nTimer)
	self.wndSettings:FindChild("SliderLabel"):SetText(string.format("Delay (%.1fs):", self.tConfig.nTimer/1000))
	
	-- Load tooltip form
	self.wndTooltip = Apollo.LoadForm(self.xmlDoc, "TooltipForm", nil, self)
	self.wndTooltip:Show(false, true)
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
		MailAttachmentGrabber.wndOverlay = Apollo.LoadForm(MailAttachmentGrabber.xmlDoc, "ButtonOverlayForm", wndOverlayParent, MailAttachmentGrabber)
	end
	
	-- Attach tooltip form
	MailAttachmentGrabber.wndOverlay:FindChild("GrabAttachmentsButton"):SetTooltipForm(MailAttachmentGrabber.wndTooltip)
	MailAttachmentGrabber.wndTooltip:Show(true)	
	
	-- Allow Mail.ToggleWindow to complete as usual
	MailAttachmentGrabber.mailToggleWindow(Mail)
	
	-- Immediately fire an update event
	MailAttachmentGrabber:MailUpdateAllListItemsIntercept()
end

-- Intercept Mail-addons "UpdateAllListItems" (which is called whenever anything has changed/needs updating)
-- so that the grab-button can be updated accordingly.
function MailAttachmentGrabber:MailUpdateAllListItemsIntercept()
	local Mail = Apollo.GetAddon("Mail")
	
	-- Allow Mail.OnUpdateAllListItemsIntercept to complete as usual
	MailAttachmentGrabber.mailUpdateAllListItems(Mail)

	-- Update and store list of selected mail IDs and attachment-summary for these mails
	MailAttachmentGrabber.tSelectedMailMap = MailAttachmentGrabber:GetSelectedMailMap()
	MailAttachmentGrabber.tEligibleMailMap = MailAttachmentGrabber:GetEligibleMailMap()
	MailAttachmentGrabber.tAttachmentsMap = MailAttachmentGrabber:GetAttachmentsMap(MailAttachmentGrabber.tEligibleMailMap)

	
	-- Update the overlay button text & tooltip
	MailAttachmentGrabber:UpdateButton()
	MailAttachmentGrabber:UpdateTooltip()
end

-- Called whenever the button text should be recalculated
function MailAttachmentGrabber:UpdateButton()
	-- Intercepted function UpdateButton may be called at times when my overlay is not present yet
	if self.wndOverlay == nil then return end	
	
	-- Locate overlay button
	local btn = self.wndOverlay:FindChild("GrabAttachmentsButton")
		
	local text 
	if self.bGrabInProgress then
		text = ""
		self.wndOverlay:FindChild("Spinner"):Show(true)
	else
		self.wndOverlay:FindChild("Spinner"):Show(false)
	
		-- Default text is "Take All"
		text = L["TakeAll"]
		
		-- If any mails are selected (even if all are selected), update text from "All" to "Selected"
		if self.tSelectedMailMap ~= nil and next(self.tSelectedMailMap) ~= nil then
			text = L["TakeSelected"]
		end
		
		-- Enable or disable, depending on attachments to grab
		btn:Enable(self.tAttachmentsMap ~= nil and next(self.tAttachmentsMap) ~= nil)		
	end
	
	-- Set button text	
	btn:SetText(text)
end

-- Scans the Mail GUI for selected mail indices. Returns list containing selected mail id-strings.
-- Empty list returned = no mails are selected
function MailAttachmentGrabber:GetSelectedMailMap()	
	local Mail = Apollo.GetAddon("Mail")
	local selectedIds = {}
	
	for idStr, wndMail in pairs(Mail.tMailItemWnds) do
		if wndMail:FindChild("SelectMarker"):IsChecked() then
			selectedIds[idStr] = true
		end		
	end
	return selectedIds
end

function MailAttachmentGrabber:GetEligibleMailMap()
	local result = {}
	
	local Mail = Apollo.GetAddon("Mail")	
	for _,mail in pairs(MailSystemLib.GetInbox()) do
		if next(self.tSelectedMailMap) == nil or self.tSelectedMailMap[mail:GetIdStr()] == true then
			-- Mail is selected (or none are selected). Include in eligible-list if it has attachments and is not COD.			
			local tMsgAttachments = mail:GetMessageInfo().arAttachments
			local bHasAttachments = (tMsgAttachments ~= nil and #tMsgAttachments)
			local bIsCOD = not mail:GetMessageInfo().monCod:IsZero()			
			local bIsGift = not mail:GetMessageInfo().monGift:IsZero()			
			
			if (not bIsCOD) and (bIsGift or bHasAttachments) then
				-- Store mail id and content summary calculations
				-- Don't store actual reference to mail object to avoid race conditions with other mail interactions
				local tEligibleMail = {}
				tEligibleMail.id = mail:GetIdStr()
				
				-- Store shorthands describing mail content
				local tMsgAttachments = mail:GetMessageInfo().arAttachments
				tEligibleMail.bHasAttachments = (tMsgAttachments ~= nil and #tMsgAttachments)
				tEligibleMail.bIsCOD = not mail:GetMessageInfo().monCod:IsZero()			
				tEligibleMail.bIsGift = not mail:GetMessageInfo().monGift:IsZero()
				
				result[tEligibleMail.id] = tEligibleMail
			end
		end
	end
	
	return result
end

-- Returns true if any of the selected mail-indices has attachments. 
-- If selectedIds input is empty, returns true if ANY mail has attachments.
function MailAttachmentGrabber:GetAttachmentsMap(tMails)
	
	-- List of attachments
	local result = {}
	
	-- Build attachment-summary table for all eligible mails
	local Mail = Apollo.GetAddon("Mail")	
	for _,mail in pairs(MailSystemLib.GetInbox()) do
		local tEligibleMail = tMails[mail:GetIdStr()]
		if tEligibleMail ~= nil then
			-- Mail is eligible. Include in summary.
			-- Add attachments summary 
			if tEligibleMail.bHasAttachments then
				for _,msgAttachment in pairs(mail:GetMessageInfo().arAttachments) do
					local itemId = msgAttachment.itemAttached:GetItemId()
					if result[itemId] ~= nil then
						-- Attachment type already seen, just add stackcount						
						result[itemId].nStackCount = result[itemId].nStackCount + msgAttachment.nStackCount
					else
						local newAttachmentType = {}
						newAttachmentType.itemAttached = msgAttachment.itemAttached
						newAttachmentType.nStackCount = msgAttachment.nStackCount						
						result[itemId] = newAttachmentType
					end
				end
			end
			
			-- Add cash summary
			if tEligibleMail.bIsGift then
				if type(result["Cash"]) ~= "number" then
					result["Cash"] = 0 
				end
				result["Cash"] = result["Cash"] + mail:GetMessageInfo().monGift:GetAmount()
			end
		end
	end
	
	return result
end

function MailAttachmentGrabber:OnGrabAttachmentsBtn()
	-- Click while grabbing is an interrupt-signal
	if self.bGrabInProgress then 
		self.bInterruptGrab = true
		return 
	end
	
	-- Indicate that grabbing is in progress to prevent futher buttonclicks from starting grabbing
	self.bGrabInProgress = true
	self.bInterruptGrab = false
	
	-- Store snapshots of eligible mails & attachment lists to use as basis for tooltip progress
	self.tMailsToProcess = {} -- "todo-list" of mails to process. Will be reduced until empty.
	self.tEligibleMailsSnapshot = {} -- Static snapshot of mails to process
	self.tAttachmentsSnapshot = {} -- Static snapshot of attachments to process
	
	for k,v in pairs(self.tEligibleMailMap) do self.tMailsToProcess[k] = v end
	for k,v in pairs(self.tEligibleMailMap) do self.tEligibleMailsSnapshot[k] = v end
	for k,v in pairs(self.tAttachmentsMap) do self.tAttachmentsSnapshot[k] = v end
	
	-- Call recursive-timer grabber function with a clone of the eligible-mail and attachment maps
	MailAttachmentGrabber:GrabAttachmentsForMail()
end

function MailAttachmentGrabber:GrabAttachmentsForMail()
	-- Update mail gui (incl. my overlay buttons/tooltip)
	self.MailUpdateAllListItemsIntercept()
	
	-- Recursion base / interrupt-signal terminates the loop
	if self.bInterruptGrab or self.tMailsToProcess == nil or next(self.tMailsToProcess) == nil then 
		self.bGrabInProgress = false
		self.bInterruptGrab = false
		return 
	end
	
	-- Get id and data of mail to process
	local id = next(self.tMailsToProcess)
	local tEligibleMail = self.tMailsToProcess[id]
	
	-- Remove this mail from list of mails to process in next recursion
	self.tMailsToProcess[id] = nil
	
	-- Look through inbox for mail with specified Id
	local Mail = Apollo.GetAddon("Mail")	
	for _,mail in pairs(MailSystemLib.GetInbox()) do
		if mail:GetIdStr() == id then
			-- Mail to grab identified. 			
			-- Safeguard against COD even though such mails should never be on this list to begin with
			if mail:GetMessageInfo().monCod:IsZero() then 
				-- Mark as read and select mail so it can be manually deleted later on
				mail:MarkAsRead()			
				Mail.tMailItemWnds[mail:GetIdStr()]:FindChild("SelectMarker"):SetCheck(true)

				if tEligibleMail.bIsGift then
					mail:TakeMoney()
				end
				
				if tEligibleMail.bHasAttachments then
					mail:TakeAllAttachments()
				end				
			end
		end
	end

	-- Recursion base / interrupt-signal terminates the loop
	if self.bInterruptGrab or self.tMailsToProcess == nil or next(self.tMailsToProcess) == nil then 
		self.bGrabInProgress = false
		self.bInterruptGrab = false
		return 
	end
	
	self.nextMailTimer = ApolloTimer.Create(self.tConfig.nTimer/1000, false, "GrabAttachmentsForMail", self)
end

function MailAttachmentGrabber:UpdateTooltip()
	if self.wndTooltip == nil then return end
	
	-- Used to determine width of tooltip window
	local maxLineWidth = 0
	
	-- Add individual item-lines to tooltip
	self.wndTooltip:DestroyChildren()
	local attachmentCount = 0
	
	-- Loop over all *original* attachment types, but get the count from the *current* set, to show a sense of progress on the tooltip
	-- When grabbing is not in progress, the "master set" is the just-before-grabbing clone
	local tMasterAttachmentMap, tMasterMailMap
	if self.bGrabInProgress then
		tMasterMailMap = self.tEligibleMailsSnapshot
		tMasterAttachmentMap = self.tAttachmentsSnapshot		
	else
		tMasterMailMap = self.tEligibleMailMap
		tMasterAttachmentMap = self.tAttachmentsMap
	end
	
	-- Completely hide tooltip if there is no work to do
	if next(tMasterAttachmentMap) == nil then
		self.wndTooltip:Show(false)
		return
	else
		self.wndTooltip:Show(true)
	end
	
	-- Get attachments left for the original mail-selection
	local tCurrentAttachments = self:GetAttachmentsMap(tMasterMailMap)
	
	for key,attachmentBeforeGrab in pairs(tMasterAttachmentMap) do
		local currentAttachment = tCurrentAttachments[key]
		attachmentCount = attachmentCount + 1
		if key == "Cash" then
			local wndLine = Apollo.LoadForm(self.xmlDoc, "TooltipCashLineForm", self.wndTooltip, MailAttachmentGrabber)
			
			-- All cash attachments may have been grabbed already, so "active" set is empty now
			local amt = 0
			if currentAttachment ~= nil then
				-- For the "Cash" key we just store the numeric cash value, not an object
				amt = currentAttachment
			end
			
			wndLine:FindChild("CashWindow"):SetAmount(amt, true)
			if maxLineWidth < 100 then maxLineWidht = 150 end
		else
			local wndLine = Apollo.LoadForm(self.xmlDoc, "TooltipItemLineForm", self.wndTooltip, MailAttachmentGrabber)
			wndLine:FindChild("ItemIcon"):SetSprite(attachmentBeforeGrab.itemAttached:GetIcon())
			
			-- All item attachments may have been grabbed already, so "active" set is empty now
			local amt = 0
			if currentAttachment ~= nil then
				amt = currentAttachment.nStackCount
			end
						
			local str = attachmentBeforeGrab.itemAttached:GetName() .. " (x" .. amt .. ")"
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
	self.wndTooltip:SetAnchorOffsets(0, 0, maxLineWidth+80, 18+attachmentCount*24)
end


--[[ Settings save/load --]]

-- Save addon config per character. Called by engine when performing a controlled game shutdown.
function MailAttachmentGrabber:OnSave(eType)
	if eType ~= GameLib.CodeEnumAddonSaveLevel.Character then 
		return 
	end

	return self.tConfig
end

-- Restore addon config per character. Called by engine when loading UI.
function MailAttachmentGrabber:OnRestore(eType, tSavedData)
	if eType ~= GameLib.CodeEnumAddonSaveLevel.Character then 
		return 
	end
	
	-- Restore savedata
	self.tConfig = tSavedData
end

function MailAttachmentGrabber:OnTimerIntervalChange(wndHandler, wndControl, fNewValue, fOldValue)
	self.tConfig.nTimer = fNewValue
	self.wndSettings:FindChild("SliderLabel"):SetText(string.format("Delay (%.1fs):", self.tConfig.nTimer/1000))
end

function MailAttachmentGrabber:OnConfigure()
	self.wndSettings:Show(true)
end

function MailAttachmentGrabber:OnHideSettings()
	self.wndSettings:Show(false, false)
end


MailAttachmentGrabber = MailAttachmentGrabber:new()
MailAttachmentGrabber:Init()
