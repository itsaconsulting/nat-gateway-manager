require 'aws-sdk-ec2'
require 'logger'
    
$client = Aws::EC2::Client.new()
$client.get_account_settings()
      
def lambda_handler(event:, context:)
  logger = Logger.new($stdout)
  logger.info('## ENVIRONMENT VARIABLES')
  logger.info(ENV.to_a)
  logger.info('## EVENT')
  logger.info(event)
  event.to_a

  # determine event type:  scale out, scale in

  # on scale out, get eip, associate eip, disable source/dest check
#  eip = get_available_eip
#  associate_address
#  disable_source_destination_check
  
  # on scale in, disassociate eip
#  disassociate_address

end


def get_available_eip()

  resp = client.describe_addresses({})
#    filters: [
#      {
#        name: "String",
#        values: ["String"],
#      },
#    ],
#    public_ips: ["String"],
#    allocation_ids: ["AllocationId"],
#    dry_run: false,
#  })

#resp.to_h outputs the following:
#{
#  addresses: [
#    {
#      domain: "standard",
#      instance_id: "i-1234567890abcdef0",
#      public_ip: "198.51.100.0",
#    },
#    {
#      allocation_id: "eipalloc-12345678",
#      association_id: "eipassoc-12345678",
#      domain: "vpc",
#      instance_id: "i-1234567890abcdef0",
#      network_interface_id: "eni-12345678",
#      network_interface_owner_id: "123456789012",
#      private_ip_address: "10.0.1.241",
#      public_ip: "203.0.113.0",
#    },
#  ],
#}

end


def associate_address()

#resp = client.associate_address({
#  allocation_id: "eipalloc-64d5890a", 
#  instance_id: "i-0b263919b6498b123", 
#})
#
#resp.to_h outputs the following:
#{
#  association_id: "eipassoc-2bebb745",
#}

end
  
  
def disassociate_address()

# disassociate an address on scale in
# resp = client.disassociate_address({
#   association_id: "eipassoc-2bebb745", 
# })

end

def disable_source_destination_check()

end


