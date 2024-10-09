# eip-update
This is a Lambda function that will update AutoScaled EC2 instances with an EIP on event from EventBridge.

**Use at your own risk!  If improperly configured or deployed, or misunderstood, this solution can restrict external access from all VPC resources.**

This is part of a solution I am working on to replace NAT Gateway resources with AutoScaled EC2 instances.

The intent is that one AutoScaling group would be deployed for each Availability Zone that resources are in.  Within each AutoScaling group, there would be a single EC2 instance that has been properly configured to serve the function of a NAT Gateway.  This can reduce costs to less than $5/month per AZ with a t4g.nano instance.  Down time should be rare and limited, depending on the stability of the Availability Zone and the EC2 instance.


#### Deployment

*Note that there are a lot of IAM details that I have not yet provided here.*

1. Create an AMI, based on the latest Amazon Linux 2023 AMI that is configured as described in [this Amazon article](https://docs.aws.amazon.com/vpc/latest/userguide/work-with-nat-instances.html).

I have another project (coming soon) that I am working on that will provide the terraform to build this AMI and update it weekly for patching/security updates.

2. Deploy an AutoScaling group in each Availability Zone / public subnet, with an EIP attached to the EC2 instance.

If replacing a current NAT Gateway, be sure to test connectivity and swap the ElasticIP from the NAT Gateway to the EC2 instance in the AutoScaling group.

3. Deploy the Lambda function and provide an environment variable to the function that will contain a map of Availability Zones to ElasticIP and [private] Route Table ID.

```
elastic_ip_to_availability_zone_mapping = {"us-west-2a":{"elastic_ip":"x.x.x.x","route_table_id":"rtb-xxxxxxxxxxxx"},"us-west-2b":{"elastic_ip":"x.x.x.x","route_table_id":"rtb-xxxxxxxxxxxx"}}
```

To test in shell before deployment, something like the following:
```
export elastic_ip_to_availability_zone_mapping='{"us-west-2a":{"elastic_ip":"x.x.x.x","route_table_id":"rtb-xxxxxxxxxxxx"},"us-west-2b":{"elastic_ip":"x.x.x.x","route_table_id":"rtb-xxxxxxxxxxxx"}}'
```

To deploy with terraform, use something like the following:

```
locals {
  elastic_ip_to_availability_zone_mapping = { 
    (var.availability_zone_a) = { 
      elastic_ip = "${aws_eip.eip_1.public_ip}",
      route_table_id = "${aws_route_table.private_1.id}"
    },  
    (var.availability_zone_b) = { 
      elastic_ip = "${aws_eip.eip_2.public_ip}",
      route_table_id: "${aws_route_table.private_2.id}"
    }   
  }
}
...
resource "aws_lambda_function" "nat_gateway_update_lambda" {
  function_name = "eip_update"
  role          = aws_iam_role.lambda_execution_role.arn
  handler       = "lambda_function.lambda_handler"
  timeout       = 15
  
  publish = true
  
  architectures = ["arm64"]
  
  s3_bucket = "yourbucket.tld"
  s3_key    = "prefix/s3_key.zip"

  runtime = "ruby3.3"
  
  environment {
    variables = {
      elastic_ip_to_availability_zone_mapping = jsonencode(local.elastic_ip_to_availability_zone_mapping)
    }
  }
}
```

4. Create an EventBridge rule that includes the following event patterns, with a target of this Lambda function.  Include a list of ARNs of the autoscaling groups in the resources list.

Note that this may not cover all required events.  I am still working through testing and validation.  If you've been to my [website](https://itsecureadmin.com/) lately and received a 502, it's because I'm testing in production.

I've moved to only take action on the event for successful launch of an EC2 instance.  This event should indicate that the newly launched instance should be the gateway instance, so it covers all the bases.

```
{
  "detail-type": ["EC2 Instance Launch Successful"],
  "resources": ["arn:aws:autoscaling:us-west-2:$aws_account_id:autoScalingGroup:$asg_id_of_some_sort_here:autoScalingGroupName/$autoscaling_group_name"],
  "source": ["aws.autoscaling"]
}
```
