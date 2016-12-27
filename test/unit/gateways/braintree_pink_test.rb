require 'test_helper'

class BraintreePinkTest < Test::Unit::TestCase
  def setup
    @gateway = BraintreePinkGateway.new(
      :access_token => 'ellies-access-token'
    )
  end


  def test_payment_method_vaulting


  end

  def test_payment_method_nonce_stuff


  end

  def test_sale_transaction

    Braintree::Transaction.expects(:purchase).
      with('transaction_id', '10.00').
      returns(braintree_result(:id => 'purchase_transaction_id'))
    response = @gateway.purchase(1000, 'transaction_id', :test => true)
    assert_equal 'purchase_transaction_id', response.authorization

  end

  def test_authorization_transaction


  end

  def test_capture_transaction


  end

  def test_refund_legacy_method_signature
    Braintree::Transaction.expects(:refund).
      with('transaction_id', nil).
      returns(braintree_result(:id => "refund_transaction_id"))
    response = @gateway.refund('transaction_id', :test => true)
    assert_equal "refund_transaction_id", response.authorization
  end

  def test_refund_method_signature
    Braintree::Transaction.expects(:refund).
      with('transaction_id', '10.00').
      returns(braintree_result(:id => "refund_transaction_id"))
    response = @gateway.refund(1000, 'transaction_id', :test => true)
    assert_equal "refund_transaction_id", response.authorization
  end

  def test_void_transaction
    Braintree::Transaction.expects(:void).
      with('transaction_id').
      returns(braintree_result(:id => "void_transaction_id"))

    response = @gateway.void('transaction_id', :test => true)
    assert_equal "void_transaction_id", response.authorization
  end

  def test_user_agent_includes_activemerchant_version
    assert Braintree::Configuration.instantiate.user_agent.include?("(ActiveMerchant #{ActiveMerchant::VERSION})")
  end

  def test_access_token_present_when_provided_on_gateway_initialization
    @gateway = BraintreePinkGateway.new(
      :access_token => 'present',
    )

    Braintree::Transaction.expects(:sale).
      with(has_entries(:access_token => "present")).
      returns(braintree_result)

    @gateway.authorize(100, credit_card("41111111111111111111"))
  end

  def test_configured_logger_has_a_default
    # The default is actually provided by the Braintree gem, but we
    # assert its presence in order to show ActiveMerchant need not
    # configure a logger
    assert Braintree::Configuration.logger.is_a?(Logger)
  end

  def test_configured_logger_has_a_default_log_level_defined_by_active_merchant
    assert_equal Logger::WARN, Braintree::Configuration.logger.level
  end

  def test_configured_logger_respects_any_custom_log_level_set_without_overwriting_it
    with_braintree_configuration_restoration do
      assert Braintree::Configuration.logger.level != Logger::DEBUG
      Braintree::Configuration.logger.level = Logger::DEBUG

      # Re-instatiate a gateway to show it doesn't affect the log level
      BraintreePinkGateway.new(
        :merchant_id => 'test',
        :public_key => 'test',
        :private_key => 'test'
      )

      assert_equal Logger::WARN, Braintree::Configuration.logger.level
    end
  end

  def test_that_setting_a_wiredump_device_on_the_gateway_sets_the_braintree_logger_upon_instantiation
    with_braintree_configuration_restoration do
      logger = Logger.new(STDOUT)
      ActiveMerchant::Billing::BraintreePinkGateway.wiredump_device = logger

      assert_not_equal logger, Braintree::Configuration.logger

      BraintreePinkGateway.new(
        :merchant_id => 'test',
        :public_key => 'test',
        :private_key => 'test'
      )

      assert_equal logger, Braintree::Configuration.logger
      assert_equal Logger::DEBUG, Braintree::Configuration.logger.level
    end
  end

  private

  def braintree_result(options = {})
    Braintree::SuccessfulResult.new(:transaction => Braintree::Transaction._new(nil, {:id => "transaction_id"}.merge(options)))
  end

  def with_braintree_configuration_restoration(&block)
    # Remember the wiredump device since we may overwrite it
    existing_wiredump_device = ActiveMerchant::Billing::BraintreePinkGateway.wiredump_device

    yield

    # Restore the wiredump device
    ActiveMerchant::Billing::BraintreePinkGateway.wiredump_device = existing_wiredump_device

    # Reset the Braintree logger
    Braintree::Configuration.logger = nil
  end
end
