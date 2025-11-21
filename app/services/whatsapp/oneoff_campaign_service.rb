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
    raise "Invalid campaign #{campaign.id}" unless whatsapp_campaign? && campaign.campaign_type_one_off?
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

    if contact.phone_number.blank?
      Rails.logger.info "Skipping contact #{contact.name} - no phone number"
      increment_statistic(:skipped_no_phone)
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

      # Remove the check that prevents sending ANY campaign - we only want to prevent duplicate from SAME campaign
      # This allows sending different campaigns to the same contact

      # Create conversation BEFORE sending to prevent race conditions
      conversation = create_campaign_conversation(contact_inbox)
      
      # Now send the message - if this fails, conversation is already marked as sent
      send_whatsapp_template_message(to: contact.phone_number, contact: contact, conversation: conversation)
      increment_statistic(:sent)
    end
  rescue ActiveRecord::RecordNotUnique, ActiveRecord::StatementInvalid => e
    # Handle race condition where conversation was created by another process
    Rails.logger.info "Skipping contact #{contact.name} (#{contact.phone_number}) - conversation already exists: #{e.message}"
    increment_statistic(:skipped_race_condition)
    nil
  rescue StandardError => e
    Rails.logger.error "Error processing contact #{contact.name}: #{e.message}"
    Rails.logger.error "Backtrace: #{e.backtrace.first(5).join('\n')}"
    increment_statistic(:failed)
    # Continue processing remaining contacts instead of failing entire campaign
    nil
  end

  def process_audience(audience_labels)
    contacts = campaign.account.contacts.tagged_with(audience_labels, any: true).distinct
    @statistics[:total] = contacts.count
    Rails.logger.info "Processing #{contacts.count} contacts for campaign #{campaign.id}"

    contacts.each { |contact| process_contact(contact) }

    Rails.logger.info "Campaign #{campaign.id} processing completed"
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
      skipped_race_condition: 0
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

    return if name.blank?

    message_id = channel.send_template(to, {
                                         name: name,
                                         namespace: namespace,
                                         lang_code: lang_code,
                                         parameters: processed_parameters
                                       }, nil)

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
    Rails.logger.error "Failed to send WhatsApp template message to #{to}: #{e.message}"
    Rails.logger.error "Backtrace: #{e.backtrace.first(5).join('\n')}"
    # Re-raise to trigger transaction rollback and skip this contact
    raise
  end
end
