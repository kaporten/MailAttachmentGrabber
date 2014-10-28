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
	
	-- Load tooltip form
	self.wndTooltip = Apollo.LoadForm(self.xmlDoc, "TooltipForm", nil, self)
	self.wndTooltip:Show(false, true)	
	
	-- Load settings form and populate values
	self.wndSettings = Apollo.LoadForm(self.xmlDoc, "SettingsForm", nil, self)
	self.wndSettings:Show(false, true)
	self.wndSettings:FindChild("Slider"):SetValue(self.tConfig.nTimer)
	self.wndSettings:FindChild("SliderLabel"):SetText(string.format("Delay (%.1fs):", self.tConfig.nTimer/1000))
	
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
		MailAttachmentGrabber.wndOverlay = Apollo.LoadForm(MailAttachmentGrabber.xmlDoc, "ButtonOverlayForm", wndOverlayParent, MailAttachmentGrabber)
	end
	
	-- Attach tooltip form
	MailAttachmentGrabber.wndOverlay:FindChild("GrabAttachmentsButton"):SetTooltipForm(MailAttachmentGrabber.wndTooltip)
	
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

	-- Only update the eligible/selected/pending lists if grabbing is not in progress.
	-- While grabbing is in progress, the pending sets will be used as baseline for status 
	-- updates so these sets must remain static while grabbing is in progress.
	if not MailAttachmentGrabber.bGrabInProgress then
		MailAttachmentGrabber.tEligibleMails = MailAttachmentGrabber:GetEligibleMails()
		MailAttachmentGrabber.tSelectedMails = MailAttachmentGrabber:GetSelectedMails()
		
		if next(MailAttachmentGrabber.tSelectedMails) ~= nil then
			-- Some mails are selected. Calculate tPendingMails as intersection between tEligibleMails and tSelectedMails
			MailAttachmentGrabber.tPendingMails = {}
			for id,_ in pairs(MailAttachmentGrabber.tSelectedMails) do
				if MailAttachmentGrabber.tEligibleMails[id] then
					MailAttachmentGrabber.tPendingMails[id] = true
				end
			end
		else
			-- No mails are selected. Set tPendingMails to tEligibleMails
			MailAttachmentGrabber.tPendingMails = MailAttachmentGrabber.tEligibleMails
		end
		
		-- For list of pending mails, build summary of pending attachments across all mails		
		MailAttachmentGrabber.tPendingAttachments = MailAttachmentGrabber:GetAttachmentsSummary(MailAttachmentGrabber.tPendingMails)		
	end	

	-- Update the overlay button text & tooltip
	MailAttachmentGrabber:UpdateButton()
	MailAttachmentGrabber:UpdateTooltip()
end

-- Scans the Mail GUI for selected mail indices. Returns list containing selected mail id-strings.
-- Empty list returned = no mails are selected
function MailAttachmentGrabber:GetSelectedMails()	
	local Mail = Apollo.GetAddon("Mail")
	local result = {}
	
	for idStr, wndMail in pairs(Mail.tMailItemWnds) do
		if wndMail:FindChild("SelectMarker"):IsChecked() then
			result[idStr] = true
		end		
	end
	return result
end

-- Gets total list of all mails which *can* be emptied
function MailAttachmentGrabber:GetEligibleMails()
	local result = {}
	local Mail = Apollo.GetAddon("Mail")
	
	for _,mail in pairs(MailSystemLib.GetInbox()) do
		local md = self:GetMailDescriptors(mail)
		
		-- Mail must have appropriate properties (not COD, contain cash or attachments)
		if (not md.bIsCOD) and (md.bIsGift or md.bHasAttachments) then
			-- Mail must be among the 50 visible mails (Mail GUI caps at 50)
			if Mail.tMailItemWnds[mail:GetIdStr()] ~= nil then
				result[mail:GetIdStr()] = true
			end
		end
	end
	return result
end

-- Returns map containing a summary of all current attachments for the specified list of mails
function MailAttachmentGrabber:GetAttachmentsSummary(tMails)
	
	-- Summarized list of attachments
	local result = {}
	
	-- Loop over all mails in the inbox
	for _,mail in pairs(MailSystemLib.GetInbox()) do
		-- Should current mail should be included in the attachments summary?
		if tMails[mail:GetIdStr()] == true then
			local md = self:GetMailDescriptors(mail)
			if not md.bIsCOD then
				if md.bHasAttachments then
					for _,attachment in pairs(mail:GetMessageInfo().arAttachments) do
						local itemId = attachment.itemAttached:GetItemId()
						if result[itemId] ~= nil then
							-- Attachment type already seen, just add stackcount						
							result[itemId].nStackCount = result[itemId].nStackCount + attachment.nStackCount
						else
							result[itemId] = {
								itemAttached = attachment.itemAttached,
								nStackCount = attachment.nStackCount
							}							
						end
					end
				end
				
				-- Add cash summary
				if md.bIsGift then
					if type(result["Cash"]) ~= "number" then
						result["Cash"] = 0 
					end
					result["Cash"] = result["Cash"] + mail:GetMessageInfo().monGift:GetAmount()
				end
			end
		end
	end
	
	return result
end

-- Reusable function for determining basic mail properties without copy/pasta logic everywhere
function MailAttachmentGrabber:GetMailDescriptors(mail)
	local descriptors = {}
	descriptors.bHasAttachments = (mail:GetMessageInfo().arAttachments ~= nil and #mail:GetMessageInfo().arAttachments > 0)
	descriptors.bIsCOD = not mail:GetMessageInfo().monCod:IsZero()			
	descriptors.bIsGift = not mail:GetMessageInfo().monGift:IsZero()
	return descriptors
end

-- Called whenever the button text should be recalculated
function MailAttachmentGrabber:UpdateButton()
	-- Intercepted function UpdateButton may be called at times when my overlay is not present yet
	if self.wndOverlay == nil then return end	
	
	-- Locate overlay button
	local button = self.wndOverlay:FindChild("GrabAttachmentsButton")
	local spinner = self.wndOverlay:FindChild("Spinner")
	
	-- Show spinner if grab is in progress
	
	-- Set text if grab is not in progress (default text is none/spinner)
	if self.bGrabInProgress then
		-- While grabbing is in progress, button should be enabled, no text, spinner shown
		button:SetText("")
		button:Enable(true)
		spinner:Show(true)
	else
		-- While grabbing is not in progress, button layout depends on selection/mailbox content
		-- Default text is "Take All"
		local text = L["TakeAll"]
		
		-- If any mails are selected (even if all are selected), update text from "All" to "Selected"
		if self.tSelectedMails ~= nil and next(self.tSelectedMails) ~= nil then
			text = L["TakeSelected"]
		end
		
		-- Enable or disable button, depending on pending attachments to grab
		button:SetText(text)
		button:Enable(self.tPendingAttachments ~= nil and next(self.tPendingAttachments) ~= nil)		
		spinner:Show(false)
	end
end

-- Button click may initiate grabbing, or set interrupt flag if grabbig is in progress
function MailAttachmentGrabber:OnGrabAttachmentsBtn()
	-- Click while grabbing is an interrupt-signal
	if self.bGrabInProgress then 
		self.bInterruptGrab = true
		return 
	end
	
	-- Indicate that grabbing is in progress to prevent futher buttonclicks from starting grabbing
	self.bGrabInProgress = true
	self.bInterruptGrab = false
	
	-- Store TODO-list of mails to process - this is essentially just a clone of tPendingMails, 
	-- sorted according to visibility in the GUI.
	self.tMailsToProcess = {}		

	local arMessages = MailSystemLib.GetInbox()
	table.sort(arMessages, Apollo.GetAddon("Mail").SortMailItems)
	for _,mail in ipairs(arMessages) do
		local idStr = mail:GetIdStr()
		if self.tPendingMails[idStr] == true then
			self.tMailsToProcess[#self.tMailsToProcess+1] = idStr
		end
	end
	
	-- Reset tMailProcessIdx to 1. This will indicate the next-to-grab index in self.tMailsToProcess recursion
	self.nMailProcessIdx = 1
	
	-- Call recursive-timer grabber function with a clone of the eligible-mail and attachment maps	
	MailAttachmentGrabber:Grab()
end

-- Main worker function. Grabs attachments for a single mail on the tMailsToProcess list, 
-- removes it and calls :Grab timer-deferred once more
function MailAttachmentGrabber:Grab()
	-- Update mail gui (incl. my overlay buttons/tooltip)
	self.MailUpdateAllListItemsIntercept()
	
	-- Recursion base / interrupt-signal terminates the loop
	if self.bInterruptGrab or self.tMailsToProcess == nil or self.nMailProcessIdx > #self.tMailsToProcess then 
		self.bGrabInProgress = false
		self.bInterruptGrab = false
		return 
	end
	
	-- Get id and data of mail to process
	local id = self.tMailsToProcess[self.nMailProcessIdx]
	
	-- Loop through inbox for mail with specified Id
	local Mail = Apollo.GetAddon("Mail")
	for _,mail in pairs(MailSystemLib.GetInbox()) do
		if mail:GetIdStr() == id then
			-- Mail to grab identified. Get descriptors so we know what to grab
			local md = self:GetMailDescriptors(mail)
			
			-- Additional safeguard against COD even though such mails should never be on this list to begin with
			if not md.bIsCOD then 
				-- Mark as read before grabbing stuff
				mail:MarkAsRead()			

				-- Grab money
				if md.bIsGift then
					mail:TakeMoney()
				end
				
				-- Grab attachments
				if md.bHasAttachments then
					mail:TakeAllAttachments()
				end				
				
				-- Select mail for easy (manual) deletion later. Safeguard against mail not being visible anymore.
				-- Could happen if it gets pushed off the 50-visible limit by incoming mail... perhaps.
				local wndMail = Mail.tMailItemWnds[mail:GetIdStr()]
				if wndMail ~= nil then
					wndMail:FindChild("SelectMarker"):SetCheck(true)
				end				
			end
		end
	end

	-- Increment self.nMailProcessIdx so next call will process next element in the queue.
	self.nMailProcessIdx = self.nMailProcessIdx + 1

	-- Check again if we've reached the end of the grab-loop. 
	-- Same check as before actual grabbing, except after nMailProcessIdx increment.
	-- No point in scheduling timer just to discover that we're done already. 
	if self.bInterruptGrab or self.tMailsToProcess == nil or self.nMailProcessIdx > #self.tMailsToProcess then 
		self.bGrabInProgress = false
		self.bInterruptGrab = false
		return 
	end
	
	-- Grab next mail via timer. Timer value defaults to 0, but using a "0 ms timer" anyway 
	-- effectively works as a yield() allowing other threads to do stuff as well.
	-- This prevents client-freeze while grab is in progress. 
	-- Divide ms (slider-config) by 1000 to get sec (timer-input). 0/1000 is still just 0 :)
	self.nextMailTimer = ApolloTimer.Create(self.tConfig.nTimer/1000, false, "Grab", self)
end

function MailAttachmentGrabber:UpdateTooltip()
	if self.wndTooltip == nil then return end
	
	-- Used to determine width of tooltip window
	local maxLineWidth = 0
	
	-- Clear out attachment window list
	local wndLines = self.wndTooltip:FindChild("LineWindow")
	wndLines:DestroyChildren()
	
	local attachmentCount = 0
	
	local tRemainingAttachments
	if self.bGrabInProgress then
		-- While grab is in progress, remaining attachments should be re-summarized off the frozen pending-mail list
		tRemainingAttachments = self:GetAttachmentsSummary(self.tPendingMails)
	else
		-- While grab is not in progress, remining attachments = pending attachments
		tRemainingAttachments = self.tPendingAttachments
	end
	
	-- Completely hide tooltip if there is no work to do
	if next(tRemainingAttachments) == nil then
		self.wndTooltip:Show(false)
		return
	else
		self.wndTooltip:Show(true)
	end
	
	-- Determine mail-count to show in tooltip. Depends on grab-in-progress or not
	local nPendingMailCount = 0
	if self.bGrabInProgress then
		-- While grabbing, calculate mails-left as maxIdx-currIdx
		-- (Add 1 since nMailProcessIdx targets next-in-line, not current)
		nPendingMailCount = #self.tMailsToProcess-self.nMailProcessIdx+1 
	else
		-- While "browsing" just count elements in nPendingMailCount
		for k,v in pairs(self.tPendingMails) do nPendingMailCount = nPendingMailCount+1 end
	end
	
	-- Set "mails to process" count message
	self.wndTooltip:FindChild("MailCountMessage"):SetText(string.format("Mails to process: %d", nPendingMailCount))
	
	-- For each of the pending (original) attachments, add a line
	for key, pendingAttachment in pairs(self.tPendingAttachments) do
		-- Get current-count from the remainingAttachments set
		local remainingAttachment = tRemainingAttachments[key]
		attachmentCount = attachmentCount + 1
		if key == "Cash" then
			local wndLine = Apollo.LoadForm(self.xmlDoc, "TooltipCashLineForm", wndLines, self)
			
			-- All cash attachments may have been grabbed already, so "active" set is empty now
			local amt = 0
			if remainingAttachment ~= nil then
				-- For the "Cash" key we just store the numeric cash value, not an object
				amt = remainingAttachment
			end
			
			wndLine:FindChild("CashWindow"):SetAmount(amt, true)
			if maxLineWidth < 100 then maxLineWidht = 150 end
		else
			local wndLine = Apollo.LoadForm(self.xmlDoc, "TooltipItemLineForm", wndLines, self)
			wndLine:FindChild("ItemIcon"):SetSprite(pendingAttachment.itemAttached:GetIcon())
			
			-- All item attachments may have been grabbed already, so "active" set is empty now
			local amt = 0
			if remainingAttachment ~= nil then
				amt = remainingAttachment.nStackCount
			end

			-- Fill out text lines. Set name to item-name, and count to remaining/pending
			local remainingCount = remainingAttachment ~= nil and remainingAttachment.nStackCount or 0
			local strCount = string.format("%d / %d", remainingCount, pendingAttachment.nStackCount)
			wndLine:FindChild("ItemName"):SetText(pendingAttachment.itemAttached:GetName())
			wndLine:FindChild("ItemCount"):SetText(strCount)
			
			-- Update max line width if this text is the longest added so far
			local nCurrLineWidth = Apollo.GetTextWidth("CRB_InterfaceSmall", wndLine:FindChild("ItemName"):GetText()) + Apollo.GetTextWidth("CRB_InterfaceSmall", wndLine:FindChild("ItemCount"):GetText()) + 15
			
			if nCurrLineWidth > maxLineWidth then maxLineWidth = nCurrLineWidth end
		end
	end
	
	-- Sort lines according to type (cash first), then ItemName
	wndLines:ArrangeChildrenVert(0, 
		function(a, b)
			if a:GetName() == "TooltipCashLineForm" then return true end
			if b:GetName() == "TooltipCashLineForm" then return false end
			return a:FindChild("ItemName"):GetText() < b:FindChild("ItemName"):GetText()
		end)
	
	-- Resize window width and height. Gief moar magic numbers plox!
	self.wndTooltip:SetAnchorOffsets(0, 0, maxLineWidth+80, 18+28+attachmentCount*24)
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
