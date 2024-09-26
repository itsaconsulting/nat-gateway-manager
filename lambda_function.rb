require 'aws-sdk-autoscaling'
require 'aws-sdk-ec2'
require 'aws-sdk-codedeploy'
require 'logger'
    
$autoscaling_client = Aws::AutoScaling::Client.new()
$ec2_client = Aws::EC2::Client.new()
$codedeploy_client = Aws::CodeDeploy::Client.new()
$logger = Logger.new($stdout)
 

def get_active_ec2_instance_id_from_asg(event:, autoscaling_group_name:)
  autoscaling_group_arn = event['resources'][0]

  resp = $autoscaling_client.describe_auto_scaling_instances()

  resp.auto_scaling_instances.each do |auto_scaling_instance|
    if auto_scaling_instance.auto_scaling_group_name == autoscaling_group_name
      $logger.info("Active AutoScaling Instance ID: #{auto_scaling_instance.instance_id}")
      return auto_scaling_instance.instance_id
    end
  end
  return 1
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
  resp = $ec2_client.describe_addresses({})

  resp['addresses'].each do |address|
    if address[:association_id].nil?
      $logger.info("Found a free EIP,AllocationId: #{address[:public_ip]}, #{address[:allocation_id]}")
      return address[:allocation_id]
    end
  end
  return 1
end

def get_instance_eip_assocation_id(ec2_instance_id:)
  resp = $ec2_client.describe_addresses({})

  resp['addresses'].each do |address|
    if address[:instance_id] == ec2_instance_id
      $logger.info("Assocation ID for instance: #{address[:association_id]}, #{address[:instance_id]}")
      return address[:association_id]
    end
  end
  return 1 # EIP not associated with this instance
end

def associate_address(ec2_instance_id:, eip_allocation_id:)
  $logger.info("Associating #{eip_allocation_id} to #{ec2_instance_id}")

  association_id = resp = $ec2_client.associate_address({
    allocation_id: eip_allocation_id,
    instance_id: ec2_instance_id,
  })

  $logger.info("Associated #{eip_allocation_id} to #{ec2_instance_id} with resulting assocation_id: #{association_id}.")
end
  
def disassociate_address(ec2_instance_id:)
  $logger.info("Disassociating EIP from: #{ec2_instance_id}.")
  association_id = get_instance_eip_assocation_id(ec2_instance_id: ec2_instance_id)

  # if there is a valid association_id, disassociate - get_instance_eip_assocation_id returns 1 when not found
  unless association_id == 1
    resp = $ec2_client.disassociate_address({
      association_id: association_id,
    })
  end
end

def disable_source_destination_check(ec2_instance_id:)
  $logger.info("Disabling source/destination check on: #{ec2_instance_id}.")
  $ec2_client.modify_instance_attribute(
    instance_id: ec2_instance_id,
    source_dest_check: {
      value: false,
    }
  )
end

def get_ec2_instance_id_from_event(event:)
  if event['detail']['EC2InstanceId'].nil?
    return 1
  else
    return event['detail']['EC2InstanceId']
  end
end

def get_autoscaling_group_name_from_event(event:)
  if event['detail']['AutoScalingGroupName'].nil?
    return 1
  else
    return event['detail']['AutoScalingGroupName']
  end
end


def lambda_handler(event:, context:)
  $logger.info('## ENVIRONMENT VARIABLES')
  $logger.info(ENV.to_a)
  $logger.info('## EVENT')
  $logger.info(event)
  event.to_a

  report_deployment_status(event:) unless event['DeploymentId'].nil?

  # on instance refresh, disassociate the EIP on the out-going instance
  if event['detail-type'] == "EC2 Auto Scaling Instance Refresh Started"
    ec2_instance_id = get_active_ec2_instance_id_from_asg(event: event, autoscaling_group_name: get_autoscaling_group_name_from_event(event: event))
    $logger.info("Disassociating EIP from #{ec2_instance_id}")
    disassociate_address(ec2_instance_id: ec2_instance_id)
#    remove_entry_from_route_table
  end

  # on instance refresh, associate the EIP on the incoming instance
  if event['detail-type'] == "EC2 Auto Scaling Instance Refresh Succeeded"
    # get the current active ec2 instance in the ASG (new instance)
    ec2_instance_id = get_active_ec2_instance_id_from_asg(event: event, autoscaling_group_name: get_autoscaling_group_name_from_event(event: event))
    $logger.info("Associating EIP to #{ec2_instance_id}")
    # associate the EIP with this instance
    eip_allocation_id = get_available_eip_allocation_id
    if eip_allocation_id == 1
      $logger.info("No free EIPs found.")
    else
      associate_address(ec2_instance_id: get_active_ec2_instance_id_from_asg(event: event, autoscaling_group_name: get_autoscaling_group_name_from_event(event: event)), eip_allocation_id: eip_allocation_id)
      disable_source_destination_check(ec2_instance_id: get_active_ec2_instance_id_from_asg(event: event, autoscaling_group_name: get_autoscaling_group_name_from_event(event: event)))
#      add_entry_to_route_table(event: event)
    end
  end



  # on scale out, get eip, associate eip, disable source/dest check, update route table(s)
  if event['detail-type'] == "EC2 Instance Launch Successful"
    $logger.info("Associating an EIP to instance #{get_ec2_instance_id_from_event(event: event)}")
    eip_allocation_id = get_available_eip_allocation_id
    if eip_allocation_id == 1
      $logger.info("No free EIPs found.")
    else
      associate_address(ec2_instance_id: get_ec2_instance_id_from_event(event:), eip_allocation_id: eip_allocation_id)
      disable_source_destination_check(ec2_instance_id: get_ec2_instance_id_from_event(event: event))
#      add_entry_to_route_table(event: event)
    end
  end

  # on scale in, disassociate eip, update route table(s)
  if event['detail-type'] == "EC2 Instance Terminate Successful"
    $logger.info("Disassociating the EIP from instance #{get_ec2_instance_id_from_event(event: event)}")
    disassociate_address(ec2_instance_id: get_ec2_instance_id_from_event(event: event))
#    remove_entry_from_route_table
  end

end

