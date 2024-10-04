require 'aws-sdk-autoscaling'
require 'aws-sdk-ec2'
require 'aws-sdk-codedeploy'
require 'logger'
require 'json'

$autoscaling_client = Aws::AutoScaling::Client.new()
$ec2_client = Aws::EC2::Client.new()
$codedeploy_client = Aws::CodeDeploy::Client.new()
$logger = Logger.new($stdout)

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

def get_active_ec2_instance_id_from_asg(autoscaling_group_name:)
  if $ec2_instance_id.nil?
    resp = $autoscaling_client.describe_auto_scaling_instances()
    resp.auto_scaling_instances.each do |auto_scaling_instance|
      if auto_scaling_instance.auto_scaling_group_name == autoscaling_group_name
        $ec2_instance_id = auto_scaling_instance.instance_id
        $logger.info("Active AutoScaling Instance ID: #{$ec2_instance_id}")
        return $ec2_instance_id
      end
    end
  else
    return $ec2_instance_id
  end
  return 1
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
    return get_active_ec2_instance_id_from_asg(autoscaling_group_name: get_autoscaling_group_name_from_event(event: event))
  else
    return event['detail']['EC2InstanceId']
  end
end

def get_availability_zone_from_event(event:)
  if event['detail']['Details']['Availability Zone'].nil?
    return 0
  else
    return event['detail']['Details']['Availability Zone']
  end
end

def get_autoscaling_group_name_from_event(event:)
  if event['detail']['AutoScalingGroupName'].nil?
    return 1
  else
    return event['detail']['AutoScalingGroupName']
  end
end

def get_route_table_id_for_ec2_instance(ec2_instance_id:)
  resp = $ec2_client.describe_route_tables()
  resp.route_tables.each do |route_table|
    route_table.routes.each do |route|
      if route.instance_id == ec2_instance_id
        return route_table.route_table_id
      end
    end
  end
  return 0
end

def get_availability_zone_for_ec2_instance(ec2_instance_id:)
  resp = $ec2_client.describe_instance_status({
    instance_ids: [
      "#{ec2_instance_id}",
    ],
  })
  return resp.instance_statuses[0].availability_zone
end

def add_entry_to_route_table(event:)
  $logger.info("Adding entry to route table.")

  if event['detail-type'].include?("EC2 Auto Scaling Instance Refresh")
    availability_zone = get_availability_zone_for_ec2_instance(ec2_instance_id: get_active_ec2_instance_id_from_asg(autoscaling_group_name: get_autoscaling_group_name_from_event(event: event)))
  else
    availability_zone = event['detail']['Details']['Availability Zone']
  end

  $logger.info("Availability Zone: #{availability_zone}")

  elastic_ip_to_availability_zone_mapping = JSON.parse(ENV['elastic_ip_to_availability_zone_mapping'])
  route_table_id = elastic_ip_to_availability_zone_mapping[availability_zone]['route_table_id']
  ec2_instance_id = get_ec2_instance_id_from_event(event: event)

  resp = $ec2_client.create_route({
    destination_cidr_block: "0.0.0.0/0",
    instance_id: ec2_instance_id,
    route_table_id: route_table_id,
  })
end

# TODO: modify the route to use another nat gateway ec2 instance, if available
def remove_entry_from_route_table(event:)
  $logger.info("Removing entry from route table.")

  ec2_instance_id = get_ec2_instance_id_from_event(event: event)

  resp = $ec2_client.describe_route_tables()
  resp.route_tables.each do |route_table|
    route_table.routes.each do |route|
      unless route.instance_id.nil?
        $logger.info(route_table.route_table_id)
        $logger.info("ec2 instance id: #{ec2_instance_id}")
        $logger.info("route instance id: #{route.instance_id}")
        if route.instance_id == ec2_instance_id
          $logger.info("Deleting route:  #{route}")
          $ec2_client.delete_route({
            destination_cidr_block: "0.0.0.0/0",
            route_table_id:  route_table.route_table_id
          })
          break
        end
      end
    end
  end
end


def lambda_handler(event:, context:)
  $logger.info('## ENVIRONMENT VARIABLES')
  $logger.info(ENV.to_a)
  $logger.info('## EVENT')
  $logger.info(event)
  event.to_a

  #
  # if this is a call by CodeDeploy, report success (ideally, perform tests and report status)
  #
  report_deployment_status(event: event) unless event['DeploymentId'].nil?

  #
  # on instance refresh, disassociate the EIP on the out-going instance
  #
  if event['detail-type'] == "EC2 Auto Scaling Instance Refresh Started"
    ec2_instance_id = get_active_ec2_instance_id_from_asg(autoscaling_group_name: get_autoscaling_group_name_from_event(event: event))
    $logger.info("Disassociating EIP from #{ec2_instance_id}")
    disassociate_address(ec2_instance_id: get_active_ec2_instance_id_from_asg(autoscaling_group_name: get_autoscaling_group_name_from_event(event: event)))
    remove_entry_from_route_table(event: event)
  end

  #
  # on instance refresh, associate the EIP on the incoming instance
  #
  if event['detail-type'] == "EC2 Auto Scaling Instance Refresh Succeeded"
    # get the current active ec2 instance in the ASG (new instance)
    ec2_instance_id = get_active_ec2_instance_id_from_asg(autoscaling_group_name: get_autoscaling_group_name_from_event(event: event))
    $logger.info("Associating EIP to #{ec2_instance_id}")
    # associate the EIP with this instance
    eip_allocation_id = get_available_eip_allocation_id
    if eip_allocation_id == 1
      $logger.info("No free EIPs found.")
    else
      associate_address(ec2_instance_id: get_active_ec2_instance_id_from_asg(autoscaling_group_name: get_autoscaling_group_name_from_event(event: event)), eip_allocation_id: eip_allocation_id)
      disable_source_destination_check(ec2_instance_id: get_active_ec2_instance_id_from_asg(autoscaling_group_name: get_autoscaling_group_name_from_event(event: event)))
      add_entry_to_route_table(event: event)
    end
  end


  #
  # on scale out, get eip, associate eip, disable source/dest check, update route table(s)
  #
  if event['detail-type'] == "EC2 Instance Launch Successful"
    $logger.info("Associating an EIP to instance #{get_ec2_instance_id_from_event(event: event)}")
    eip_allocation_id = get_available_eip_allocation_id
    if eip_allocation_id == 1
      $logger.info("No free EIPs found.")
    else
      associate_address(ec2_instance_id: get_ec2_instance_id_from_event(event: event), eip_allocation_id: eip_allocation_id)
      disable_source_destination_check(ec2_instance_id: get_ec2_instance_id_from_event(event: event))
      add_entry_to_route_table(event: event)
    end
  end

  #
  # on scale in, disassociate eip, update route table(s)
  #
  if event['detail-type'] == "EC2 Instance Terminate Successful"
    $logger.info("Disassociating the EIP from instance #{get_ec2_instance_id_from_event(event: event)}")
    disassociate_address(ec2_instance_id: get_ec2_instance_id_from_event(event: event))
    remove_entry_from_route_table(event: event)
  end

end

