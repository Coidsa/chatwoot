class Whatsapp::OneoffCampaignService
  pattr_initialize [:campaign!]

  def perform
    validate_campaign!
    initialize_statistics
    process_audience(extract_audience_labels)
    update_campaign_statistics
    campaign.completed!
  end

  private

  delegate :inbox, to: :campaign
  delegate :channel, to: :inbox

  def validate_campaign_type!
    raise "Invalid campaign #{campaign.id}" unless whatsapp_campaign? && campaign.one_off?
  end

  def whatsapp_campaign?
    campaign.inbox.inbox_type == 'Whatsapp'
  end

  def validate_campaign_status!
    raise 'Completed Campaign' if campaign.completed?
  end

  def validate_provider!
    raise 'WhatsApp Cloud provider required' if channel.provider != 'whatsapp_cloud'
  end

  def validate_feature_flag!
    raise 'WhatsApp campaigns feature not enabled' unless campaign.account.feature_enabled?(:whatsapp_campaign)
  end

  def validate_campaign!
    validate_campaign_type!
    validate_campaign_status!
    validate_provider!
    validate_feature_flag!
  end

  def extract_audience_labels
    audience_label_ids = campaign.audience.select { |audience| audience['type'] == 'Label' }.pluck('id')
    campaign.account.labels.where(id: audience_label_ids).pluck(:title)
  end

  def process_contact(contact)
    Rails.logger.info "Processing contact: #{contact.name} (#{contact.phone_number})"
    increment_statistic(:total) unless @statistics[:total] > 0 # Don't double count if total was already set

    if contact.phone_number.blank?
      Rails.logger.info "Skipping contact #{contact.name} - no phone number"
      increment_statistic(:skipped_no_phone)
      return
    end

    # Validate phone number format for WhatsApp (must start with +)
    unless contact.phone_number.start_with?('+')
      Rails.logger.info "Skipping contact #{contact.name} (#{contact.phone_number}) - invalid phone number format (must start with +)"
      increment_statistic(:skipped_invalid_phone)
      return
    end

    if campaign.template_params.blank?
      Rails.logger.error "Skipping contact #{contact.name} - no template_params found for WhatsApp campaign"
      increment_statistic(:skipped_no_template)
      return
    end

    # Use transaction with locking to prevent duplicate sends
    ActiveRecord::Base.transaction do
      # Find or create contact_inbox inside transaction with lock
      contact_inbox = inbox.contact_inboxes.find_or_create_by!(contact: contact)
      contact_inbox.lock!

      # Check if conversation already exists with this campaign
      existing_conversation = Conversation.find_by(
        account: campaign.account,
        inbox: inbox,
        contact: contact,
        contact_inbox: contact_inbox,
        campaign_id: campaign.id
      )

      if existing_conversation
        Rails.logger.info "Skipping contact #{contact.name} (#{contact.phone_number}) - already received message from campaign #{campaign.id} (conversation_id: #{existing_conversation.id})"
        increment_statistic(:skipped_duplicate_campaign)
        return
      end

      # Create conversation BEFORE sending to prevent race conditions
      conversation = create_campaign_conversation(contact_inbox)
      
      # Now send the message - if this fails, conversation is already marked as sent
      send_whatsapp_template_message(to: contact.phone_number, contact: contact, conversation: conversation)
      increment_statistic(:sent)
      Rails.logger.info "Successfully processed contact #{contact.name} (#{contact.phone_number})"
    end
  rescue ActiveRecord::RecordNotUnique, ActiveRecord::StatementInvalid => e
    # Handle race condition where conversation was created by another process
    Rails.logger.info "Skipping contact #{contact.name} (#{contact.phone_number}) - conversation already exists: #{e.message}"
    increment_statistic(:skipped_race_condition)
    nil
  rescue StandardError => e
    Rails.logger.error "Error processing contact #{contact.name} (#{contact.phone_number}): #{e.class} - #{e.message}"
    Rails.logger.error "Backtrace: #{e.backtrace.first(10).join('\n')}"
    increment_statistic(:failed)
    # Continue processing remaining contacts instead of failing entire campaign
    nil
  end

  def process_audience(audience_labels)
    contacts = campaign.account.contacts.tagged_with(audience_labels, any: true).distinct
    @statistics[:total] = contacts.count
    Rails.logger.info "Processing #{contacts.count} contacts for campaign #{campaign.id}"
    Rails.logger.info "Campaign statistics initialized: #{@statistics.inspect}"

    processed_count = 0
    contacts.find_each do |contact|
      process_contact(contact)
      processed_count += 1
      
      # Log progress every 100 contacts
      if processed_count % 100 == 0
        Rails.logger.info "Campaign #{campaign.id} progress: #{processed_count}/#{contacts.count} contacts processed. Statistics: #{@statistics.inspect}"
      end
    end

    Rails.logger.info "Campaign #{campaign.id} processing completed. Final statistics: #{@statistics.inspect}"
  end

  def create_campaign_conversation(contact_inbox)
    # Use create! instead of find_or_create_by! because we already checked for existence
    # This ensures we get an error if somehow a conversation was created between check and create
    Conversation.create!(
      account: campaign.account,
      inbox: inbox,
      contact: contact_inbox.contact,
      contact_inbox: contact_inbox,
      campaign_id: campaign.id,
      status: :open,
      last_activity_at: Time.current
    )
  end

  def initialize_statistics
    @statistics = {
      total: 0,
      sent: 0,
      delivered: 0,
      read: 0,
      failed: 0,
      skipped_no_phone: 0,
      skipped_no_template: 0,
      skipped_duplicate_campaign: 0,
      skipped_race_condition: 0,
      skipped_invalid_phone: 0
    }
  end

  def increment_statistic(key)
    @statistics[key] = (@statistics[key] || 0) + 1
  end

  def update_campaign_statistics
    # Store statistics in trigger_rules JSONB field
    stats = campaign.trigger_rules || {}
    stats['statistics'] = @statistics.merge(
      completed_at: Time.current,
      updated_at: Time.current
    )
    campaign.update_column(:trigger_rules, stats)
    Rails.logger.info "Campaign #{campaign.id} statistics: #{@statistics.inspect}"
  end

  def send_whatsapp_template_message(to:, contact: nil, conversation: nil)
    processor = Whatsapp::TemplateProcessorService.new(
      channel: channel,
      template_params: campaign.template_params
    )

    name, namespace, lang_code, processed_parameters = processor.call

    if name.blank?
      Rails.logger.error "Failed to process template for #{to}: template name is blank"
      raise "Template name is blank"
    end

    Rails.logger.info "Sending WhatsApp template to #{to}: template=#{name}, namespace=#{namespace}, lang=#{lang_code}"

    message_id = channel.send_template(to, {
                                         name: name,
                                         namespace: namespace,
                                         lang_code: lang_code,
                                         parameters: processed_parameters
                                       }, nil)

    if message_id.blank?
      Rails.logger.error "Failed to send WhatsApp template message to #{to}: message_id is blank (API returned nil)"
      raise "Message ID is blank - API call may have failed"
    end

    # Create message record if conversation is provided
    if conversation && message_id.present?
      conversation.messages.create!(
        account: campaign.account,
        inbox: inbox,
        sender: conversation.contact,
        content: campaign.message,
        message_type: :outgoing,
        status: :sent,
        source_id: message_id,
        additional_attributes: {
          campaign_id: campaign.id,
          template_params: campaign.template_params
        }
      )
    end

    Rails.logger.info "Successfully sent WhatsApp template message to #{to} (message_id: #{message_id})"

  rescue StandardError => e
    Rails.logger.error "Failed to send WhatsApp template message to #{to}: #{e.class} - #{e.message}"
    Rails.logger.error "Backtrace: #{e.backtrace.first(10).join('\n')}"
    # Re-raise to trigger transaction rollback and skip this contact
    raise
  end
end
