class Whatsapp::OneoffCampaignService
  pattr_initialize [:campaign!]

  def perform
    Rails.logger.info "=" * 80
    Rails.logger.info "🎯 Starting WhatsApp Oneoff Campaign Service"
    Rails.logger.info "Campaign ID: #{campaign.id}"
    Rails.logger.info "Campaign Title: #{campaign.title}"
    Rails.logger.info "Inbox: #{inbox.name} (ID: #{inbox.id})"
    Rails.logger.info "Account: #{campaign.account.name} (ID: #{campaign.account.id})"
    Rails.logger.info "=" * 80
    
    validate_campaign!
    initialize_statistics
    process_audience(extract_audience_labels)
    update_campaign_statistics
    campaign.completed!
    
    Rails.logger.info "=" * 80
    Rails.logger.info "✅ WhatsApp Oneoff Campaign Service completed"
    Rails.logger.info "Final Statistics: #{@statistics.inspect}"
    Rails.logger.info "=" * 80
  rescue StandardError => e
    Rails.logger.error "=" * 80
    Rails.logger.error "❌ ERROR in WhatsApp Oneoff Campaign Service"
    Rails.logger.error "Campaign ID: #{campaign.id}"
    Rails.logger.error "Error: #{e.class} - #{e.message}"
    Rails.logger.error "Backtrace: #{e.backtrace.first(15).join('\n')}"
    Rails.logger.error "=" * 80
    raise
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

    # Use ContactInboxBuilder to ensure proper source_id is set for WhatsApp
    # ContactInboxBuilder automatically generates source_id from phone_number (removes +)
    # WhatsApp source_id must match regex: ^\d{1,15}\z (digits only, 1-15 characters, no +)
    contact_inbox = ContactInboxBuilder.new(
      contact: contact,
      inbox: inbox,
      source_id: nil # Let builder generate it from phone_number
    ).perform
    
    unless contact_inbox
      Rails.logger.error "Failed to create contact_inbox for contact #{contact.name} (#{contact.phone_number})"
      increment_statistic(:skipped_invalid_phone)
      return
    end
    
    # Validate source_id format after creation (should already be validated, but double-check)
    unless contact_inbox.source_id.match?(/^\d{1,15}$/)
      Rails.logger.error "Invalid source_id format for contact #{contact.name} (#{contact.phone_number}): #{contact_inbox.source_id}"
      Rails.logger.error "Source_id must be 1-15 digits only (regex: ^\\d{1,15}\\z)"
      increment_statistic(:skipped_invalid_phone)
      return
    end

    # Simple check: if conversation already exists with this campaign, skip
    existing_conversation = Conversation.find_by(
      account: campaign.account,
      inbox: inbox,
      contact: contact,
      campaign_id: campaign.id
    )

    if existing_conversation
      Rails.logger.info "Skipping contact #{contact.name} (#{contact.phone_number}) - already received message from campaign #{campaign.id} (conversation_id: #{existing_conversation.id})"
      increment_statistic(:skipped_duplicate_campaign)
      return
    end

    # Create conversation - use create! to get error if already exists (race condition protection)
    conversation = Conversation.create!(
      account: campaign.account,
      inbox: inbox,
      contact: contact,
      contact_inbox: contact_inbox,
      campaign_id: campaign.id,
      status: :open,
      last_activity_at: Time.current
    )
    
    # Send message after conversation is created
    send_whatsapp_template_message(to: contact.phone_number, contact: contact, conversation: conversation)
    increment_statistic(:sent)
    Rails.logger.info "Successfully processed contact #{contact.name} (#{contact.phone_number})"
    
  rescue ActiveRecord::RecordNotUnique => e
    # Handle race condition where conversation was created by another process between check and create
    Rails.logger.info "Skipping contact #{contact.name} (#{contact.phone_number}) - conversation already exists (race condition): #{e.message}"
    increment_statistic(:skipped_duplicate_campaign)
    nil
  rescue ActiveRecord::RecordInvalid => e
    # Handle validation errors (e.g., source_id validation)
    error_msg = e.message
    Rails.logger.error "=" * 80
    Rails.logger.error "Validation error for contact #{contact.name} (#{contact.phone_number})"
    Rails.logger.error "Error: #{error_msg}"
    Rails.logger.error "Phone number: #{contact.phone_number}"
    Rails.logger.error "Attempted source_id: #{source_id rescue 'unknown'}"
    Rails.logger.error "=" * 80
    
    if error_msg.include?('source') || error_msg.include?('Source') || error_msg.include?('source_id')
      increment_statistic(:skipped_invalid_phone)
      Rails.logger.error "Categorized as: INVALID_PHONE_NUMBER"
    else
      increment_statistic(:failed)
      Rails.logger.error "Categorized as: OTHER_VALIDATION_ERROR"
    end
    nil
  rescue StandardError => e
    error_class = e.class.name
    error_message = e.message
    full_error = "#{error_class}: #{error_message}"
    
    # Print to STDOUT for terminal visibility (in addition to logger)
    puts "\n" + "=" * 80
    puts "❌ ERROR processing contact #{contact.name} (#{contact.phone_number})"
    puts "Error Class: #{error_class}"
    puts "Error Message: #{error_message}"
    puts "Full Error: #{full_error}"
    
    # Log detailed error information
    Rails.logger.error "=" * 80
    Rails.logger.error "ERROR processing contact #{contact.name} (#{contact.phone_number})"
    Rails.logger.error "Error Class: #{error_class}"
    Rails.logger.error "Error Message: #{error_message}"
    Rails.logger.error "Full Error: #{full_error}"
    
    # Categorize errors for better statistics
    error_category = nil
    if error_message.include?('phone number') || error_message.include?('invalid') || error_message.include?('format') || error_message.include?('source') || error_message.include?('Source')
      error_category = "INVALID_PHONE_NUMBER"
      puts "Error Category: #{error_category}"
      Rails.logger.error "Error Category: #{error_category}"
      increment_statistic(:skipped_invalid_phone)
    elsif error_message.include?('template') || error_message.include?('Template') || error_message.include?('TEMPLATE')
      error_category = "TEMPLATE_ERROR"
      puts "Error Category: #{error_category}"
      Rails.logger.error "Error Category: #{error_category}"
      increment_statistic(:skipped_no_template)
    elsif error_message.include?('rate limit') || error_message.include?('Rate limit') || error_message.include?('429')
      error_category = "RATE_LIMIT"
      puts "Error Category: #{error_category}"
      Rails.logger.error "Error Category: #{error_category}"
      increment_statistic(:failed)
    elsif error_message.include?('access token') || error_message.include?('unauthorized') || error_message.include?('401') || error_message.include?('authentication')
      error_category = "AUTHENTICATION_ERROR"
      puts "Error Category: #{error_category}"
      puts "⚠️  WARNING: Check WhatsApp API credentials!"
      Rails.logger.error "Error Category: #{error_category}"
      Rails.logger.error "⚠️  WARNING: Check WhatsApp API credentials!"
      increment_statistic(:failed)
    else
      error_category = "GENERAL_ERROR"
      puts "Error Category: #{error_category}"
      Rails.logger.error "Error Category: #{error_category}"
      increment_statistic(:failed)
    end
    
    # Store sample errors for reporting (keep only first 10 to avoid bloating statistics)
    if @statistics[:error_details].length < 10
      @statistics[:error_details] << {
        phone: contact.phone_number,
        error_class: error_class,
        error_message: error_message.length > 100 ? error_message[0..100] + '...' : error_message,
        error_category: error_category
      }
    end
    
    # Print backtrace to terminal (first 10 lines)
    puts "\nBacktrace (first 10 lines):"
    e.backtrace.first(10).each_with_index do |line, idx|
      puts "  #{idx + 1}. #{line}"
    end
    
    Rails.logger.error "Backtrace: #{e.backtrace.first(15).join('\n')}"
    puts "=" * 80 + "\n"
    Rails.logger.error "=" * 80
    
    # Continue processing remaining contacts instead of failing entire campaign
    nil
  end

  def process_audience(audience_labels)
    contacts = campaign.account.contacts.tagged_with(audience_labels, any: true).distinct
    @statistics[:total] = contacts.count
    
    Rails.logger.info "=" * 80
    Rails.logger.info "🚀 Starting Campaign Processing"
    Rails.logger.info "Campaign ID: #{campaign.id}"
    Rails.logger.info "Campaign Title: #{campaign.title}"
    Rails.logger.info "Total Contacts: #{contacts.count}"
    Rails.logger.info "Statistics initialized: #{@statistics.inspect}"
    Rails.logger.info "=" * 80

    processed_count = 0
    error_count = 0
    
    contacts.find_each do |contact|
      begin
        process_contact(contact)
      rescue => e
        error_count += 1
        # Errors are already logged in process_contact rescue block
      end
      
      processed_count += 1
      
      # Log progress every 100 contacts
      if processed_count % 100 == 0
        Rails.logger.info "-" * 80
        Rails.logger.info "📊 Campaign #{campaign.id} Progress: #{processed_count}/#{contacts.count} contacts processed"
        Rails.logger.info "Statistics: #{@statistics.inspect}"
        Rails.logger.info "Errors encountered so far: #{error_count}"
        Rails.logger.info "-" * 80
      end
    end

    # Print final statistics
    Rails.logger.info "=" * 80
    Rails.logger.info "✅ Campaign #{campaign.id} Processing Completed!"
    Rails.logger.info "Final Statistics:"
    @statistics.each do |key, value|
      next if key == :error_details # Skip error_details in summary
      Rails.logger.info "  - #{key}: #{value}" if value.to_i > 0
    end
    
    # Show error samples if available
    if @statistics[:error_details]&.any?
      Rails.logger.info ""
      Rails.logger.info "📋 Sample Errors (first #{[@statistics[:error_details].length, 5].min}):"
      @statistics[:error_details].first(5).each_with_index do |error, idx|
        Rails.logger.info "  #{idx + 1}. Phone: #{error[:phone]}"
        Rails.logger.info "     Error: #{error[:error_class]} - #{error[:error_message]}"
      end
    end
    
    Rails.logger.info "=" * 80
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
      skipped_invalid_phone: 0,
      error_details: [] # Store sample errors for debugging
    }
  end

  def increment_statistic(key)
    @statistics[key] = (@statistics[key] || 0) + 1
  end

  def update_campaign_statistics
    # Store statistics in trigger_rules JSONB field
    stats = campaign.trigger_rules || {}
    
    # Convert error_details to hash format for JSONB storage (keep only first 10)
    error_details_hash = @statistics[:error_details].first(10).map do |error|
      {
        phone: error[:phone],
        category: error[:error_category],
        message: error[:error_message]
      }
    end
    
    # Store statistics including error details and summary
    stats['statistics'] = @statistics.except(:error_details).merge(
      completed_at: Time.current.iso8601,
      updated_at: Time.current.iso8601,
      error_summary: summarize_errors,
      error_samples: error_details_hash
    )
    
    campaign.update_column(:trigger_rules, stats)
    Rails.logger.info "Campaign #{campaign.id} statistics: #{@statistics.except(:error_details).inspect}"
    Rails.logger.info "Error summary: #{summarize_errors.inspect}"
  end
  
  def summarize_errors
    summary = {}
    @statistics[:error_details].each do |error|
      category = error[:error_category] || 'UNKNOWN'
      summary[category] = (summary[category] || 0) + 1
    end
    summary
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
    error_details = {
      phone: to,
      error_class: e.class.name,
      error_message: e.message,
      timestamp: Time.current
    }
    
    # Store first 10 errors as samples
    if @statistics[:error_details].length < 10
      @statistics[:error_details] << error_details
    end
    
    # Print to STDOUT for terminal visibility
    puts "\n" + "-" * 80
    puts "❌ Failed to send WhatsApp template message"
    puts "Phone: #{to}"
    puts "Error Class: #{e.class.name}"
    puts "Error Message: #{e.message}"
    puts "Full Error: #{error_details.inspect}"
    
    # Print backtrace (first 5 lines)
    puts "\nBacktrace (first 5 lines):"
    e.backtrace.first(5).each_with_index do |line, idx|
      puts "  #{idx + 1}. #{line}"
    end
    puts "-" * 80 + "\n"
    
    Rails.logger.error "Failed to send WhatsApp template message to #{to}: #{e.class} - #{e.message}"
    Rails.logger.error "Full error: #{error_details.inspect}"
    Rails.logger.error "Backtrace: #{e.backtrace.first(10).join('\n')}"
    
    # Re-raise to trigger transaction rollback and skip this contact
    raise
  end
end
