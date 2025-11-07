# TODO: logic is written tailored to contact import since its the only import available
# let's break this logic and clean this up in future

class DataImportJob < ApplicationJob
  queue_as :low
  retry_on ActiveStorage::FileNotFoundError, wait: 1.minute, attempts: 3

  def perform(data_import)
    @data_import = data_import
    @contact_manager = DataImport::ContactManager.new(@data_import.account)
    begin
      process_import_file
      send_import_notification_to_admin
    rescue CSV::MalformedCSVError => e
      handle_csv_error(e)
    end
  end

  private

  def process_import_file
    @data_import.update!(status: :processing)
    contacts, rejected_contacts = parse_csv_and_build_contacts

    import_contacts(contacts)
    update_data_import_status(contacts.length, rejected_contacts.length)
    save_failed_records_csv(rejected_contacts)
  end

  def parse_csv_and_build_contacts
    contacts = []
    rejected_contacts = []
    @labels_mapping = {}
    # Ensuring that importing non utf-8 characters will not throw error
    data = @data_import.import_file.download
    utf8_data = data.force_encoding('UTF-8')

    # Ensure that the data is valid UTF-8, preserving valid characters
    clean_data = utf8_data.valid_encoding? ? utf8_data : utf8_data.encode('UTF-16le', invalid: :replace, replace: '').encode('UTF-8')

    csv = CSV.parse(clean_data, headers: true)

    csv.each do |row|
      row_hash = row.to_h.with_indifferent_access
      current_contact = @contact_manager.build_contact(row_hash)
      if current_contact.valid?
        contacts << current_contact
        # Store labels for this contact using a unique identifier
        labels = @contact_manager.parse_labels(row_hash[:labels])
        if labels.present?
          contact_key = build_contact_key(row_hash)
          @labels_mapping[contact_key] = labels
        end
      else
        append_rejected_contact(row, current_contact, rejected_contacts)
      end
    end

    [contacts, rejected_contacts]
  end

  def append_rejected_contact(row, contact, rejected_contacts)
    row['errors'] = contact.errors.full_messages.join(', ')
    rejected_contacts << row
  end

  def import_contacts(contacts)
    # <struct ActiveRecord::Import::Result failed_instances=[], num_inserts=1, ids=[444, 445], results=[]>
    Contact.import(contacts, synchronize: contacts, on_duplicate_key_ignore: true, track_validation_failures: true, validate: true, batch_size: 1000)
    assign_labels_to_contacts
  end

  def update_data_import_status(processed_records, rejected_records)
    @data_import.update!(status: :completed, processed_records: processed_records, total_records: processed_records + rejected_records)
  end

  def save_failed_records_csv(rejected_contacts)
    csv_data = generate_csv_data(rejected_contacts)
    return if csv_data.blank?

    @data_import.failed_records.attach(io: StringIO.new(csv_data), filename: "#{Time.zone.today.strftime('%Y%m%d')}_contacts.csv",
                                       content_type: 'text/csv')
    send_import_notification_to_admin
  end

  def generate_csv_data(rejected_contacts)
    headers = CSV.parse(@data_import.import_file.download, headers: true).headers
    headers << 'errors'
    return if rejected_contacts.blank?

    CSV.generate do |csv|
      csv << headers
      rejected_contacts.each do |record|
        csv << record
      end
    end
  end

  def handle_csv_error(error) # rubocop:disable Lint/UnusedMethodArgument
    @data_import.update!(status: :failed)
    send_import_failed_notification_to_admin
  end

  def send_import_notification_to_admin
    AdministratorNotifications::AccountNotificationMailer.with(account: @data_import.account).contact_import_complete(@data_import).deliver_later
  end

  def send_import_failed_notification_to_admin
    AdministratorNotifications::AccountNotificationMailer.with(account: @data_import.account).contact_import_failed.deliver_later
  end

  def build_contact_key(row_hash)
    # Use identifier, email, or phone_number as unique key to match contacts after import
    # Format phone number consistently for matching
    if row_hash[:identifier].present?
      { type: :identifier, value: row_hash[:identifier] }
    elsif row_hash[:email].present?
      { type: :email, value: row_hash[:email].downcase }
    elsif row_hash[:phone_number].present?
      { type: :phone_number, value: format_phone_number_for_search(row_hash[:phone_number]) }
    end
  end

  def assign_labels_to_contacts
    return if @labels_mapping.blank?

    @labels_mapping.each do |contact_key, labels|
      next unless contact_key

      contact = find_contact_by_key(contact_key)
      next unless contact

      contact.add_labels(labels)
    end
  end

  def find_contact_by_key(key_hash)
    return nil unless key_hash

    case key_hash[:type]
    when :identifier
      @data_import.account.contacts.find_by(identifier: key_hash[:value])
    when :email
      @data_import.account.contacts.from_email(key_hash[:value])
    when :phone_number
      @data_import.account.contacts.find_by(phone_number: key_hash[:value])
    end
  end

  def format_phone_number_for_search(phone_number)
    return nil if phone_number.blank?

    phone_number.start_with?('+') ? phone_number : "+#{phone_number}"
  end
end
