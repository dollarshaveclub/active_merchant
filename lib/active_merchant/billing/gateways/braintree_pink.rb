require 'active_merchant/billing/gateways/braintree/braintree_common'

begin
  require "braintree"
rescue LoadError
  raise "Could not load the braintree gem.  Use `gem install braintree` to install it."
end

unless Braintree::Version::Major == 2 && Braintree::Version::Minor >= 4
  raise "Need braintree gem >= 2.4.0. Run `gem install braintree --version '~>2.4'` to get the correct version."
end

module ActiveMerchant #:nodoc:
  module Billing #:nodoc:
    # For more information on the Braintree Gateway please visit their
    # {Developer Portal}[https://www.braintreepayments.com/developers]
    #
    # ==== About this implementation
    #
    # This implementation leverages the Braintree-authored ruby gem:
    # https://github.com/braintree/braintree_ruby
    #
    # ==== Debugging Information
    #
    # Setting an ActiveMerchant +wiredump_device+ will automatically
    # configure the Braintree logger (via the Braintree gem's
    # configuration) when the BraintreeBlueGateway is instantiated.
    # Additionally, the log level will be set to +DEBUG+. Therefore,
    # all you have to do is set the +wiredump_device+ and you'll get
    # your debug output from your HTTP interactions with the remote
    # gateway. (Don't enable this in production.) The ActiveMerchant
    # implementation doesn't mess with the Braintree::Configuration
    # globals at all, so there won't be any side effects outside
    # Active Merchant.
    #
    # If no +wiredump_device+ is set, the logger in
    # +Braintree::Configuration.logger+ will be cloned and the log
    # level set to +WARN+.
    #
    class BraintreePinkGateway < Gateway
      include BraintreeCommon

      self.display_name = 'Braintree (Pink Platform)'

      def initialize(options = {})
        requires!(options, :access_token)
        @merchant_account_id = options[:merchant_account_id]

        super

        if wiredump_device.present?
          logger = ((Logger === wiredump_device) ? wiredump_device : Logger.new(wiredump_device))
          logger.level = Logger::DEBUG
        else
          logger = Braintree::Configuration.logger.clone
          logger.level = Logger::WARN
        end

        @configuration = Braintree::Configuration.new(
          :access_token      => options[:access_token],
          :environment       => (options[:environment] || (test? ? :sandbox : :production)).to_sym,
          :custom_user_agent => "ActiveMerchant #{ActiveMerchant::VERSION}",
          :logger            => options[:logger] || logger,
        )

        @braintree_gateway = Braintree::Gateway.new( @configuration )
      end

      def authorize(money, credit_card_or_vault_id, options = {})
        create_transaction(:sale, money, credit_card_or_vault_id, options)
      end

      def capture(money, authorization, options = {})
        commit do
          result = @braintree_gateway.transaction.submit_for_settlement(authorization, amount(money).to_s)
          response_from_result(result)
        end
      end

      def purchase(money, credit_card_or_vault_id, options = {})
        authorize(money, credit_card_or_vault_id, options.merge(:submit_for_settlement => true))
      end

      def credit(money, credit_card_or_vault_id, options = {})
        create_transaction(:credit, money, credit_card_or_vault_id, options)
      end

      def refund(*args)
        # legacy signature: #refund(transaction_id, options = {})
        # new signature: #refund(money, transaction_id, options = {})
        money, transaction_id, _ = extract_refund_args(args)
        money = amount(money).to_s if money

        commit do
          response_from_result(@braintree_gateway.transaction.refund(transaction_id, money))
        end
      end

      def void(authorization, options = {})
        commit do
          response_from_result(@braintree_gateway.transaction.void(authorization))
        end
      end

      private

      def map_address(address)
        return {} if address.nil?
        mapped = {
          :first_name => address[:first_name],
          :last_name => address[:last_name],
          :street_address => address[:address1],
          :extended_address => address[:address2],
          :company => address[:company],
          :locality => address[:city],
          :region => address[:state],
          :postal_code => scrub_zip(address[:zip]),
        }
        if(address[:country] || address[:country_code_alpha2])
          mapped[:country_code_alpha2] = (address[:country] || address[:country_code_alpha2])
        elsif address[:country_name]
          mapped[:country_name] = address[:country_name]
        elsif address[:country_code_alpha3]
          mapped[:country_code_alpha3] = address[:country_code_alpha3]
        elsif address[:country_code_numeric]
          mapped[:country_code_numeric] = address[:country_code_numeric]
        end
        mapped
      end

      def commit(&block)
        yield
      rescue Braintree::BraintreeError => ex
        Response.new(false, ex.class.to_s)
      end

      def message_from_result(result)
        if result.success?
          "OK"
        elsif result.errors.any?
          result.errors.map { |e| "#{e.message} (#{e.code})" }.join(" ")
        elsif result.credit_card_verification
          "Processor declined: #{result.credit_card_verification.processor_response_text} (#{result.credit_card_verification.processor_response_code})"
        else
          result.message.to_s
        end
      end

      def response_from_result(result)
        Response.new(result.success?, message_from_result(result),
          { braintree_transaction: transaction_hash(result) },
          { authorization: (result.transaction.id if result.transaction) }
         )
      end

      def response_params(result)
        params = {}
        params[:customer_vault_id] = result.transaction.customer_details.id if result.success?
        params[:braintree_transaction] = transaction_hash(result)
        params
      end

      def response_options(result)
        options = {}
        if result.transaction
          options[:authorization] = result.transaction.id
          options[:avs_result] = { code: avs_code_from(result.transaction) }
          options[:cvv_result] = result.transaction.cvv_response_code
        end
        options
      end

      def avs_code_from(transaction)
        transaction.avs_error_response_code ||
          avs_mapping["street: #{transaction.avs_street_address_response_code}, zip: #{transaction.avs_postal_code_response_code}"]
      end

      def avs_mapping
        {
          "street: M, zip: M" => "M",
          "street: M, zip: N" => "A",
          "street: M, zip: U" => "B",
          "street: M, zip: I" => "B",
          "street: M, zip: A" => "B",

          "street: N, zip: M" => "Z",
          "street: N, zip: N" => "C",
          "street: N, zip: U" => "C",
          "street: N, zip: I" => "C",
          "street: N, zip: A" => "C",

          "street: U, zip: M" => "P",
          "street: U, zip: N" => "N",
          "street: U, zip: U" => "I",
          "street: U, zip: I" => "I",
          "street: U, zip: A" => "I",

          "street: I, zip: M" => "P",
          "street: I, zip: N" => "C",
          "street: I, zip: U" => "I",
          "street: I, zip: I" => "I",
          "street: I, zip: A" => "I",

          "street: A, zip: M" => "P",
          "street: A, zip: N" => "C",
          "street: A, zip: U" => "I",
          "street: A, zip: I" => "I",
          "street: A, zip: A" => "I"
        }
      end

      def message_from_transaction_result(result)
        if result.transaction && result.transaction.status == "gateway_rejected"
          "Transaction declined - gateway rejected"
        elsif result.transaction
          "#{result.transaction.processor_response_code} #{result.transaction.processor_response_text}"
        else
          message_from_result(result)
        end
      end

      def response_code_from_result(result)
        if result.transaction
          result.transaction.processor_response_code
        elsif result.errors.size == 0 && result.credit_card_verification
          result.credit_card_verification.processor_response_code
        elsif result.errors.size > 0
          result.errors.first.code
        end
      end

      def create_transaction(transaction_type, money, credit_card_or_vault_id, options)
        transaction_params = create_transaction_parameters(money, credit_card_or_vault_id, options)
        commit do
          result = @braintree_gateway.transaction.send(transaction_type, transaction_params)
          response = Response.new(result.success?, message_from_transaction_result(result), response_params(result), response_options(result))
          response.cvv_result['message'] = ''
          response
        end
      end

      def extract_refund_args(args)
        options = args.extract_options!

         money, transaction_id, options
        if args.length == 1 # legacy signature
          return nil, args[0], options
        elsif args.length == 2
          return args[0], args[1], options
        else
          raise ArgumentError, "wrong number of arguments (#{args.length} for 2)"
        end
      end

      def transaction_hash(result)
        unless result.success?
          return { "processor_response_code" => response_code_from_result(result) }
        end

        transaction = result.transaction
        if transaction.vault_customer
          vault_customer = {
          }
          vault_customer["credit_cards"] = transaction.vault_customer.credit_cards.map do |cc|
            {
              "bin" => cc.bin
            }
          end
        else
          vault_customer = nil
        end

        customer_details = {
          "id" => transaction.customer_details.id,
          "email" => transaction.customer_details.email
        }

        billing_details = {
          "street_address"   => transaction.billing_details.street_address,
          "extended_address" => transaction.billing_details.extended_address,
          "company"          => transaction.billing_details.company,
          "locality"         => transaction.billing_details.locality,
          "region"           => transaction.billing_details.region,
          "postal_code"      => transaction.billing_details.postal_code,
          "country_name"     => transaction.billing_details.country_name,
        }

        shipping_details = {
          "street_address"   => transaction.shipping_details.street_address,
          "extended_address" => transaction.shipping_details.extended_address,
          "company"          => transaction.shipping_details.company,
          "locality"         => transaction.shipping_details.locality,
          "region"           => transaction.shipping_details.region,
          "postal_code"      => transaction.shipping_details.postal_code,
          "country_name"     => transaction.shipping_details.country_name,
        }
        credit_card_details = {
          "masked_number"       => transaction.credit_card_details.masked_number,
          "bin"                 => transaction.credit_card_details.bin,
          "last_4"              => transaction.credit_card_details.last_4,
          "card_type"           => transaction.credit_card_details.card_type,
          "token"               => transaction.credit_card_details.token
        }

        {
          "order_id"                => transaction.order_id,
          "status"                  => transaction.status,
          "credit_card_details"     => credit_card_details,
          "customer_details"        => customer_details,
          "billing_details"         => billing_details,
          "shipping_details"        => shipping_details,
          "vault_customer"          => vault_customer,
          "merchant_account_id"     => transaction.merchant_account_id,
          "processor_response_code" => response_code_from_result(result)
        }
      end

      def create_transaction_parameters(money, credit_card_or_vault_id, options)
        parameters = {
          :amount => amount(money).to_s,
          :order_id => options[:order_id],
          :options => {
            :paypal => {
              :custom_field => options[:custom_field],
              :store_in_vault_on_success => options[:store_in_vault_on_success] ? true : false,
              :description => options[:description],
              :submit_for_settlement => options[:submit_for_settlement],
            }
          }
        }

        #setting merchant id
        parameters[:custom_fields] = options[:custom_fields]
        if merchant_account_id = (options[:merchant_account_id] || @merchant_account_id)
          parameters[:merchant_account_id] = merchant_account_id
        end

        #how we are going to support "vaulting" and using payment method tokens later
        if credit_card_or_vault_id.is_a?(String) || credit_card_or_vault_id.is_a?(Integer)
          if options[:payment_method_token]
            parameters[:payment_method_token] = credit_card_or_vault_id
            options.delete(:billing_address)
          elsif options[:payment_method_nonce]
            parameters[:payment_method_nonce] = credit_card_or_vault_id
        end

        #adding in shipping address
        parameters[:shipping] = map_address(options[:shipping_address]) if options[:shipping_address]

        #descriptor options
        if options[:descriptor_name] || options[:descriptor_phone] || options[:descriptor_url]
          parameters[:descriptor] = {
            name: options[:descriptor_name],
            phone: options[:descriptor_phone],
            url: options[:descriptor_url]
          }
        end

        parameters
      end
    end
  end
end
