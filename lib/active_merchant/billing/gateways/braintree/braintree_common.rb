module BraintreeCommon
  def self.included(base)
    base.supported_countries = ['US', 'AU']
    puts "TREES"
    puts base.supported_countries[0]
    puts base.supported_countries[1]
    base.supported_cardtypes = [:visa, :master, :american_express, :discover, :jcb, :diners_club]
    base.homepage_url = 'http://www.braintreepaymentsolutions.com'
    base.display_name = 'Braintree'
    base.default_currency = 'USD'
  end
end