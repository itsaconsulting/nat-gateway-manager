require 'aws-sdk-ec2'
require 'aws-sdk-codedeploy'
require 'logger'
    
$client = Aws::EC2::Client.new()
$codedeploy_client = Aws::CodeDeploy::Client.new()
$logger = Logger.new($stdout)
 
def lambda_handler(event:, context:)
  $logger.info('## ENVIRONMENT VARIABLES')
  $logger.info(ENV.to_a)
  $logger.info('## EVENT')
  $logger.info(event)
  event.to_a

  report_deployment_status(event:) unless event['DeploymentId'].nil?

  # on scale out, get eip, associate eip, disable source/dest check, update route table(s)
  if event['detail-type'] == "EC2 Instance Launch Successful"
    $logger.info("Associating an EIP to instance #{get_ec2_instance_id_from_event(event:)}")
    eip_allocation_id = get_available_eip_allocation_id
    if eip_allocation_id == 0
      $logger.info("No free EIPs found.")
      exit 1
    end
    associate_address(event:, eip_allocation_id:)
    disable_source_destination_check(ec2_instance_id: get_ec2_instance_id_from_event(event:))
#    add_entry_to_route_table(event:)
  end

  # on scale in, disassociate eip, update route table(s)
  if event['detail-type'] == "EC2 Instance Terminate Successful"
    $logger.info("Disassociating the EIP from instance #{get_ec2_instance_id_from_event(event:)}")
    disassociate_address(event:)
#    remove_entry_from_route_table
  end

end


def report_deployment_status(event:)

  $logger.info('## Reporting Success to CodeDeploy.')
  deployment_id = event["DeploymentId"]

  lifecycle_event_hook_execution_id = event["LifecycleEventHookExecutionId"]

  resp = $codedeploy_client.put_lifecycle_event_hook_execution_status({
    deployment_id: deployment_id,
    lifecycle_event_hook_execution_id: lifecycle_event_hook_execution_id,
    status: "Succeeded",
  })
end

def get_available_eip_allocation_id()
  resp = $client.describe_addresses({})

  resp['addresses'].each do |address|
    if address[:association_id].nil?
      $logger.info("Found a free EIP,AllocationId: #{address[:public_ip]}, #{address[:allocation_id]}")
      return address[:allocation_id]
    end
  end
  return 0
end

def get_instance_eip_assocation_id(ec2_instance_id:)
  resp = $client.describe_addresses({})

  resp['addresses'].each do |address|
    if address[:instance_id] == ec2_instance_id
      $logger.info("Assocation ID for instance: #{address[:association_id]}, #{address[:instance_id]}")
      return address[:association_id]
    end
  end
end



def associate_address(event:, eip_allocation_id:)
  $logger.info("Associating #{eip_allocation_id} to #{get_ec2_instance_id_from_event(event:)}")

  association_id = resp = $client.associate_address({
    allocation_id: eip_allocation_id,
    instance_id: get_ec2_instance_id_from_event(event:),
  })

  $logger.info("Associated #{eip_allocation_id} to #{get_ec2_instance_id_from_event(event:)} with resulting assocation_id: #{association_id}.")
end
  
def disassociate_address(event:)
  $logger.info("Disassociating EIP from: #{get_ec2_instance_id_from_event(event:)}.")
  association_id = get_instance_eip_assocation_id(ec2_instance_id: get_ec2_instance_id_from_event(event:))

  resp = $client.disassociate_address({
    association_id: association_id,
  })
end

def disable_source_destination_check(ec2_instance_id:)
  $logger.info("Disabling source/destination check on: #{ec2_instance_id}.")
  $client.modify_instance_attribute(
    instance_id: ec2_instance_id,
    source_dest_check: {
      value: false,
    }
  )
end

def get_ec2_instance_id_from_event(event:)
  if event['detail']['EC2InstanceId'].nil?
    return 0
  else
    return event['detail']['EC2InstanceId']
  end
end

