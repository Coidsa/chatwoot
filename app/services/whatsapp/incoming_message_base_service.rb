# Mostly modeled after the intial implementation of the service based on 360 Dialog
# https://docs.360dialog.com/whatsapp-api/whatsapp-api/media
# https://developers.facebook.com/docs/whatsapp/api/media/
class Whatsapp::IncomingMessageBaseService
  include ::Whatsapp::IncomingMessageServiceHelpers

  pattr_initialize [:inbox!, :params!]

  def perform
    processed_params

    if processed_params.try(:[], :statuses).present?
      process_statuses
    elsif processed_params.try(:[], :messages).present?
      process_messages
    end
  end

  private

  def process_messages
    # We don't support reactions & ephemeral message now, we need to skip processing the message
    # if the webhook event is a reaction or an ephermal message or an unsupported message.
    return if unprocessable_message_type?(message_type)

    # Multiple webhook event can be received against the same message due to misconfigurations in the Meta
    # business manager account. While we have not found the core reason yet, the following line ensure that
    # there are no duplicate messages created.
    return if find_message_by_source_id(@processed_params[:messages].first[:id]) || message_under_process?

    cache_message_source_id_in_redis
    set_contact
    return unless @contact

    ActiveRecord::Base.transaction do
      set_conversation
      create_messages
      clear_message_source_id_from_redis
    end
  end

  def process_statuses
    status_data = @processed_params[:statuses].first
    message_id = status_data[:id]
    new_status = status_data[:status]
    
    Rails.logger.info "Processing WhatsApp status update: message_id=#{message_id}, status=#{new_status}, recipient=#{status_data[:recipient_id]}"
    
    message = find_message_by_source_id(message_id)
    unless message
      Rails.logger.warn "Message not found for source_id: #{message_id} - status update ignored"
      return
    end

    Rails.logger.info "Found message: id=#{message.id}, current_status=#{message.status}, campaign_id=#{message.additional_attributes&.dig('campaign_id')}"
    
    update_message_with_status(message, status_data)
  rescue ArgumentError => e
    Rails.logger.error "Error while processing whatsapp status update: #{e.message}"
    Rails.logger.error "Backtrace: #{e.backtrace.first(5).join('\n')}"
  rescue StandardError => e
    Rails.logger.error "Unexpected error processing status update: #{e.class} - #{e.message}"
    Rails.logger.error "Backtrace: #{e.backtrace.first(10).join('\n')}"
  end

  def update_message_with_status(message, status)
    old_status = message.status
    message.status = status[:status]
    if status[:status] == 'failed' && status[:errors].present?
      error = status[:errors]&.first
      message.external_error = "#{error[:code]}: #{error[:title]}"
    end
    message.save!
    
    # Update campaign statistics if this message is from a campaign
    update_campaign_statistics_from_message_status(message, old_status, status[:status])
  end

  def update_campaign_statistics_from_message_status(message, old_status, new_status)
    campaign_id = message.additional_attributes&.dig('campaign_id')
    
    unless campaign_id
      Rails.logger.debug "Message #{message.id} has no campaign_id in additional_attributes - skipping statistics update"
      return
    end

    campaign = Campaign.find_by(id: campaign_id)
    unless campaign
      Rails.logger.warn "Campaign #{campaign_id} not found for message #{message.id} - skipping statistics update"
      return
    end

    # Skip if status didn't actually change
    if old_status.to_s == new_status.to_s
      Rails.logger.debug "Message #{message.id} status unchanged (#{old_status}) - skipping statistics update"
      return
    end

    Rails.logger.info "Updating campaign #{campaign.id} statistics: message #{message.id} status changed from #{old_status} to #{new_status}"

    # Update statistics based on status transition
    # Status flow: sent -> delivered -> read (can't go backwards in normal flow)
    old_status_s = old_status.to_s
    new_status_s = new_status.to_s
    
    # Use pessimistic locking to prevent race conditions
    campaign.with_lock do
      stats = campaign.reload.trigger_rules&.dig('statistics') || {}
      sent_count = stats['sent'] || 0
      initial_delivered = stats['delivered'] || 0
      initial_read = stats['read'] || 0
      initial_failed = stats['failed'] || 0
      
      case new_status_s
      when 'delivered'
        # Only increment if transitioning from sent to delivered
        # Also ensure delivered never exceeds sent
        if old_status_s == 'sent' && (stats['delivered'] || 0) < sent_count
          stats['delivered'] = (stats['delivered'] || 0) + 1
          Rails.logger.info "Campaign #{campaign.id}: Incremented delivered count (now: #{stats['delivered']}/#{sent_count})"
        else
          Rails.logger.debug "Campaign #{campaign.id}: Skipping delivered increment (old_status: #{old_status_s}, delivered: #{stats['delivered'] || 0}, sent: #{sent_count})"
        end
        
      when 'read'
        # Only increment if transitioning from delivered/sent to read
        # Ensure read never exceeds delivered (or sent if delivered not tracked)
        max_delivered = [(stats['delivered'] || 0), sent_count].max
        if (old_status_s == 'delivered' || old_status_s == 'sent') && (stats['read'] || 0) < max_delivered
          stats['read'] = (stats['read'] || 0) + 1
          # If transitioning from sent directly to read, also count as delivered (but only if it doesn't exceed sent)
          if old_status_s == 'sent' && (stats['delivered'] || 0) < sent_count
            stats['delivered'] = (stats['delivered'] || 0) + 1
            Rails.logger.info "Campaign #{campaign.id}: Incremented delivered count (now: #{stats['delivered']}/#{sent_count})"
          end
          Rails.logger.info "Campaign #{campaign.id}: Incremented read count (now: #{stats['read']}/#{max_delivered})"
        else
          Rails.logger.debug "Campaign #{campaign.id}: Skipping read increment (old_status: #{old_status_s}, read: #{stats['read'] || 0}, max_delivered: #{max_delivered})"
        end
        
      when 'failed'
        # Only increment if transitioning from sent to failed
        # Ensure failed doesn't cause delivered+failed to exceed sent
        if old_status_s == 'sent'
          stats['failed'] = (stats['failed'] || 0) + 1
          Rails.logger.info "Campaign #{campaign.id}: Incremented failed count (now: #{stats['failed']}/#{sent_count})"
        end
      end

      # Safety check: ensure delivered never exceeds sent
      if stats['delivered'] && stats['delivered'] > sent_count
        Rails.logger.warn "Campaign #{campaign.id}: Correcting delivered count (#{stats['delivered']}) to not exceed sent (#{sent_count})"
        stats['delivered'] = sent_count
      end
      
      # Safety check: ensure read never exceeds delivered (or sent)
      max_allowed_read = [(stats['delivered'] || 0), sent_count].max
      if stats['read'] && stats['read'] > max_allowed_read
        Rails.logger.warn "Campaign #{campaign.id}: Correcting read count (#{stats['read']}) to not exceed max allowed (#{max_allowed_read})"
        stats['read'] = max_allowed_read
      end

      # Update campaign statistics
      trigger_rules = campaign.trigger_rules || {}
      trigger_rules['statistics'] = stats
      campaign.update_column(:trigger_rules, trigger_rules)
      
      Rails.logger.info "Campaign #{campaign.id} statistics updated: sent=#{sent_count}, delivered=#{stats['delivered'] || 0}, read=#{stats['read'] || 0}, failed=#{stats['failed'] || 0}"
    end
  rescue StandardError => e
    Rails.logger.error "Error updating campaign #{campaign_id} statistics for message #{message.id}: #{e.class} - #{e.message}"
    Rails.logger.error "Backtrace: #{e.backtrace.first(10).join('\n')}"
  end

  def create_messages
    message = @processed_params[:messages].first
    log_error(message) && return if error_webhook_event?(message)

    process_in_reply_to(message)

    message_type == 'contacts' ? create_contact_messages(message) : create_regular_message(message)
  end

  def create_contact_messages(message)
    message['contacts'].each do |contact|
      create_message(contact)
      attach_contact(contact)
      @message.save!
    end
  end

  def create_regular_message(message)
    create_message(message)
    attach_files
    attach_location if message_type == 'location'
    @message.save!
  end

  def set_contact
    contact_params = @processed_params[:contacts]&.first
    return if contact_params.blank?

    waid = processed_waid(contact_params[:wa_id])

    contact_inbox = ::ContactInboxWithContactBuilder.new(
      source_id: waid,
      inbox: inbox,
      contact_attributes: { name: contact_params.dig(:profile, :name), phone_number: "+#{@processed_params[:messages].first[:from]}" }
    ).perform

    @contact_inbox = contact_inbox
    @contact = contact_inbox.contact

    # Update existing contact name if ProfileName is available and current name is just phone number
    update_contact_with_profile_name(contact_params)
  end

  def set_conversation
    # if lock to single conversation is disabled, we will create a new conversation if previous conversation is resolved
    @conversation = if @inbox.lock_to_single_conversation
                      @contact_inbox.conversations.last
                    else
                      @contact_inbox.conversations
                                    .where.not(status: :resolved).last
                    end
    return if @conversation

    @conversation = ::Conversation.create!(conversation_params)
  end

  def attach_files
    return if %w[text button interactive location contacts].include?(message_type)

    attachment_payload = @processed_params[:messages].first[message_type.to_sym]
    @message.content ||= attachment_payload[:caption]

    attachment_file = download_attachment_file(attachment_payload)
    return if attachment_file.blank?

    @message.attachments.new(
      account_id: @message.account_id,
      file_type: file_content_type(message_type),
      file: {
        io: attachment_file,
        filename: attachment_file.original_filename,
        content_type: attachment_file.content_type
      }
    )
  end

  def attach_location
    location = @processed_params[:messages].first['location']
    location_name = location['name'] ? "#{location['name']}, #{location['address']}" : ''
    @message.attachments.new(
      account_id: @message.account_id,
      file_type: file_content_type(message_type),
      coordinates_lat: location['latitude'],
      coordinates_long: location['longitude'],
      fallback_title: location_name,
      external_url: location['url']
    )
  end

  def create_message(message)
    @message = @conversation.messages.build(
      content: message_content(message),
      account_id: @inbox.account_id,
      inbox_id: @inbox.id,
      message_type: :incoming,
      sender: @contact,
      source_id: message[:id].to_s,
      in_reply_to_external_id: @in_reply_to_external_id
    )
  end

  def attach_contact(contact)
    phones = contact[:phones]
    phones = [{ phone: 'Phone number is not available' }] if phones.blank?

    name_info = contact['name'] || {}
    contact_meta = {
      firstName: name_info['first_name'],
      lastName: name_info['last_name']
    }.compact

    phones.each do |phone|
      @message.attachments.new(
        account_id: @message.account_id,
        file_type: file_content_type(message_type),
        fallback_title: phone[:phone].to_s,
        meta: contact_meta
      )
    end
  end

  def update_contact_with_profile_name(contact_params)
    profile_name = contact_params.dig(:profile, :name)
    return if profile_name.blank?
    return if @contact.name == profile_name

    # Only update if current name exactly matches the phone number or formatted phone number
    return unless contact_name_matches_phone_number?

    @contact.update!(name: profile_name)
  end

  def contact_name_matches_phone_number?
    phone_number = "+#{@processed_params[:messages].first[:from]}"
    formatted_phone_number = TelephoneNumber.parse(phone_number).international_number
    @contact.name == phone_number || @contact.name == formatted_phone_number
  end
end
