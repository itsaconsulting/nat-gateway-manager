require 'aws-sdk-autoscaling'
require 'aws-sdk-ec2'
require 'aws-sdk-codedeploy'
require 'logger'
require 'json'

$autoscaling_client = Aws::AutoScaling::Client.new
$ec2_client = Aws::EC2::Client.new
$codedeploy_client = Aws::CodeDeploy::Client.new
$logger = Logger.new($stdout)

def report_deployment_status(event:)
  $logger.debug('## Reporting Success to CodeDeploy.')

  resp = $codedeploy_client.put_lifecycle_event_hook_execution_status({
    deployment_id: event['DeploymentId'],
    lifecycle_event_hook_execution_id: event["LifecycleEventHookExecutionId"],
    status: 'Succeeded'
  })
end

def get_ec2_instance_associated_with_eip(elastic_ip:)
  resp = $ec2_client.describe_addresses({})
  resp['addresses'].each do |address|
    return address[:instance_id] if address[:public_ip] == elastic_ip
  end
  return 1 # no instance associated with this EIP
end

def get_eip_allocation_id(elastic_ip:)
  resp = $ec2_client.describe_addresses({})
  resp['addresses'].each do |address|
    return address[:allocation_id] if address[:public_ip] == elastic_ip
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
  $logger.debug("Associating #{eip_allocation_id} to #{ec2_instance_id}")

  association_id = $ec2_client.associate_address({
    allocation_id: eip_allocation_id,
    instance_id: ec2_instance_id
  })

  $logger.debug("Associated #{eip_allocation_id} to #{ec2_instance_id} with resulting assocation_id: #{association_id}.")
end

def disassociate_address(ec2_instance_id:)
  $logger.info("Disassociating EIP from: #{ec2_instance_id}.")
  association_id = get_instance_eip_assocation_id(ec2_instance_id: ec2_instance_id)

  # if there is a valid association_id, disassociate - get_instance_eip_assocation_id returns 1 when not found
  unless association_id == 1
    resp = $ec2_client.disassociate_address({
      association_id: association_id
    })
  end
end

def disable_source_destination_check(ec2_instance_id:)
  $logger.info("Disabling source/destination check on: #{ec2_instance_id}.")
  $ec2_client.modify_instance_attribute(
    instance_id: ec2_instance_id,
    source_dest_check: {
      value: false
    }
  )
end

def get_ec2_instance_id_from_event(event:)
  return event['detail']['EC2InstanceId'] unless event['detail']['EC2InstanceId'].nil?
end

def get_availability_zone_from_event(event:)
  if event['detail-type'].include?('EC2 Auto Scaling Instance Refresh')
    return get_availability_zone_for_ec2_instance(ec2_instance_id: get_active_ec2_instance_id_from_asg(autoscaling_group_name: get_autoscaling_group_name_from_event(event: event)))
  else
    return event['detail']['Details']['Availability Zone']
  end
end

def add_entry_to_route_table(event:)
  $logger.debug('Adding entry to route table.')

  elastic_ip_to_availability_zone_mapping = JSON.parse(ENV['elastic_ip_to_availability_zone_mapping'])

  $ec2_client.create_route({
    destination_cidr_block: '0.0.0.0/0',
    instance_id: get_ec2_instance_id_from_event(event: event),
    route_table_id: elastic_ip_to_availability_zone_mapping[get_availability_zone_from_event(event: event)]['route_table_id']
  })
end

def get_route_table_id_for_availability_zone(event:)
  elastic_ip_to_availability_zone_mapping = JSON.parse(ENV['elastic_ip_to_availability_zone_mapping'])
  return elastic_ip_to_availability_zone_mapping[get_availability_zone_from_event(event: event)]['route_table_id']
end

def remove_entry_from_route_table(route_table_id:)
  resp = $ec2_client.describe_route_tables()
  resp.route_tables.each do |route_table|
    route_table.routes.each do |route|
      if route_table.route_table_id == route_table_id
        $logger.debug(route_table.route_table_id)
        if route.destination_cidr_block == '0.0.0.0/0'
          $logger.debug("Deleting route:  #{route}")
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

def get_elastic_ip_for_availability_zone(event:)
  elastic_ip_to_availability_zone_mapping = JSON.parse(ENV['elastic_ip_to_availability_zone_mapping'])
  return elastic_ip_to_availability_zone_mapping[get_availability_zone_from_event(event: event)]['elastic_ip']
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
  # on new instance launch, get eip, associate eip, disable source/dest check, update route table(s)
  # - assume that any newly launched instance should be the latest/current active instance and should have the EIP
  #
  if event['detail-type'] == 'EC2 Instance Launch Successful'
    $logger.debug("Associating an EIP to instance #{get_ec2_instance_id_from_event(event: event)}")
    elastic_ip = get_elastic_ip_for_availability_zone(event: event)
    disassociate_address(ec2_instance_id: get_ec2_instance_associated_with_eip(elastic_ip: elastic_ip)) if get_ec2_instance_associated_with_eip(elastic_ip: elastic_ip) != 1
    associate_address(
      ec2_instance_id: get_ec2_instance_id_from_event(event: event),
      eip_allocation_id: get_eip_allocation_id(elastic_ip: elastic_ip
    ))
    disable_source_destination_check(ec2_instance_id: get_ec2_instance_id_from_event(event: event))
    remove_entry_from_route_table(route_table_id: get_route_table_id_for_availability_zone(event: event))
    add_entry_to_route_table(event: event)
  end
end
